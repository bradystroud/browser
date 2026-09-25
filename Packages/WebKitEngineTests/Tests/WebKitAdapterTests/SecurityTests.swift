import XCTest
@testable import WebKitAdapter

/// Two loopback servers on different ports are two different origins, which
/// is all a cross-origin attack needs.
@MainActor
class TwoOriginTestCase: WebKitTabTestCase {
    var other: LocalHTTPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        other = try LocalHTTPServer(routes: routes())
        try other.start()
    }

    override func tearDownWithError() throws {
        other?.stop()
        other = nil
        try super.tearDownWithError()
    }

    func origin(of server: LocalHTTPServer) -> WebOrigin {
        WebOrigin(urlString: server.url("/"))!
    }
}

/// Page messages carry the engine's own account of the sending frame, and
/// PageMessagePolicy turns a message from anywhere but the tab's own main
/// frame away -- whatever the page wrote into it.
final class PageMessageSourceTests: TwoOriginTestCase {
    private static let forgedSubmit = """
    {"type":"passwordFormSubmit","origin":"https://bank.example","username":"victim","password":"hunter2"}
    """

    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/outer": .html("<!DOCTYPE html><title>Outer</title><p>host page</p>"),
            // What a hostile ad iframe would do: claim to be some other site.
            "/attack": .html("""
                <!DOCTYPE html><title>Attack</title>
                <script>
                window.cefQuery({request: \(Self.jsString(Self.forgedSubmit)), onSuccess: function(){}, onFailure: function(){}});
                </script>
                """),
        ]
    }

    private static func jsString(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        recorder.onPageMessage = { [weak self] _, requestId in
            self?.tab.respondToPageMessage(requestId: requestId, success: true, response: "")
        }
        loadAndWaitForCommit(server.url("/outer"))
    }

    private var tabState: PageMessageTabState {
        PageMessageTabState(engineURL: server.url("/outer"), isShowingStartPage: false)
    }

    func testCrossOriginIframeMessageIsFlaggedAndRejected() throws {
        _ = try callJS("""
            const frame = document.createElement('iframe');
            frame.src = src;
            document.body.appendChild(frame);
            return true;
            """, arguments: ["src": other.url("/attack")])
        waitUntil("iframe's forged message arrives") { !recorder.pageMessages.isEmpty }
        let message = try XCTUnwrap(recorder.pageMessages.first)

        XCTAssertFalse(message.source.isMainFrame)
        XCTAssertEqual(message.source.origin, origin(of: other), "the engine reports the iframe's real origin, not the payload's")
        XCTAssertEqual(message.source.frameURL, other.url("/attack"))
        guard case .reject = PageMessagePolicy.evaluate(type: "passwordFormSubmit", source: message.source, tab: tabState) else {
            return XCTFail("a cross-origin iframe's password message must be rejected")
        }
    }

    func testMainFrameOriginComesFromTheEngineNotThePayload() throws {
        _ = try callJS("""
            window.cefQuery({request: request, onSuccess: function(){}, onFailure: function(){}});
            return true;
            """, arguments: ["request": Self.forgedSubmit])
        waitUntil("main frame message arrives") { !recorder.pageMessages.isEmpty }
        let message = try XCTUnwrap(recorder.pageMessages.first)

        XCTAssertTrue(message.source.isMainFrame)
        XCTAssertEqual(message.source.origin, origin(of: server))
        XCTAssertEqual(PageMessagePolicy.evaluate(type: "passwordFormSubmit", source: message.source, tab: tabState),
                       .allow(origin: origin(of: server)),
                       "the payload's https://bank.example must play no part in the verdict")
    }

    /// The start page is recognized by its exact data: URL, so the frame URL
    /// WebKit reports must be byte-for-byte the one that was loaded.
    func testDataURLMainFrameReportsItsExactURL() throws {
        let html = "<!DOCTYPE html><title>Start</title><p>start page</p>"
        let dataURL = "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString()
        loadAndWaitForCommit(dataURL)
        _ = try callJS("""
            window.cefQuery({request: '{"type":"openStartPageSettings"}', onSuccess: function(){}, onFailure: function(){}});
            return true;
            """)
        waitUntil("start page message arrives") { !recorder.pageMessages.isEmpty }
        let source = try XCTUnwrap(recorder.pageMessages.first?.source)
        XCTAssertTrue(source.isMainFrame)
        XCTAssertEqual(source.frameURL, dataURL)
        XCTAssertNil(source.origin)
        XCTAssertEqual(PageMessagePolicy.evaluate(type: "openStartPageSettings", source: source,
                                                  tab: PageMessageTabState(engineURL: dataURL, isShowingStartPage: true)),
                       .allow(origin: nil))
    }
}

/// Page-opened windows: no gesture, no window; and never a data:/file:/
/// javascript: top-level load, gesture or not.
final class PopupSecurityTests: TwoOriginTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/blank": .html("<!DOCTYPE html><title>Blank</title><a id='plain' href='/target'>plain</a>"),
            "/target": .html("<!DOCTYPE html><title>Target</title>"),
            // Tries every way to open a window without the user doing
            // anything. The last attempt, a synthetic ⌘-click, is expected to
            // navigate this tab in place: WebKit does not carry an untrusted
            // event's modifiers into the navigation action.
            "/spam": .html("""
                <!DOCTYPE html><title>Spam</title>
                <a id="blank" href="/target" target="_blank">blank</a>
                <a id="plain" href="/target">plain</a>
                <script>
                window.open('/target');
                setTimeout(function() { window.open('/target', '_blank', 'width=300,height=300'); }, 20);
                setTimeout(function() { document.getElementById('blank').click(); }, 40);
                setTimeout(function() {
                  document.getElementById('plain').dispatchEvent(
                    new MouseEvent('click', { bubbles: true, cancelable: true, metaKey: true }));
                }, 300);
                </script>
                """),
        ]
    }

    func testPopupsWithoutAUserGestureAreRefused() {
        loadAndWaitForCommit(server.url("/spam"))
        waitUntil("page finished trying") { recorder.events.contains("title:Target") }
        settle(0.5)
        XCTAssertTrue(recorder.events(named: "popup").isEmpty, "no-gesture popup got through: \(recorder.events)")
        XCTAssertTrue(recorder.events(named: "newTab").isEmpty, "no-gesture new tab got through: \(recorder.events)")
    }

    /// evaluateJavaScript/callAsyncJavaScript run as a user gesture, so this
    /// isolates the target check from the gesture check.
    func testGestureOpensAnHTTPPopup() throws {
        loadAndWaitForCommit(server.url("/blank"))
        let opened = try callJS("return window.open(url) !== null;", arguments: ["url": other.url("/target")]) as? Bool
        XCTAssertEqual(opened, true)
        waitUntil("popup created") { !recorder.events(named: "popup").isEmpty }
    }

    func testDataURLPopupIsRefusedEvenWithAGesture() throws {
        loadAndWaitForCommit(server.url("/blank"))
        let opened = try callJS("return window.open('data:text/html,<h1>phish</h1>') !== null;") as? Bool
        XCTAssertEqual(opened, false)
        settle(0.3)
        XCTAssertTrue(recorder.events(named: "popup").isEmpty)
    }

    func testOtherDangerousSchemesAreRefused() throws {
        loadAndWaitForCommit(server.url("/blank"))
        for url in ["file:///etc/hosts", "javascript:alert(1)"] {
            _ = try callJS("window.open(url); return true;", arguments: ["url": url])
        }
        settle(0.3)
        XCTAssertTrue(recorder.events(named: "popup").isEmpty, "\(recorder.events)")
    }

    func testSameOriginBlobPopupIsAllowed() throws {
        loadAndWaitForCommit(server.url("/blank"))
        let opened = try callJS("""
            const url = URL.createObjectURL(new Blob(['<h1>mine</h1>'], { type: 'text/html' }));
            return window.open(url) !== null;
            """) as? Bool
        XCTAssertEqual(opened, true)
        waitUntil("popup created") { !recorder.events(named: "popup").isEmpty }
    }
}

/// The warning page's "Continue anyway" link only ever lifts the warning for
/// the exact URL that warning was shown for.
final class ThreatContinueTests: TwoOriginTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/risky": .html("<!DOCTYPE html><title>Risky</title>"),
            "/elsewhere": .html("<!DOCTYPE html><title>Elsewhere</title>"),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        WebKitEngine.setThreatInterstitialBuilder { _, originalURL in
            let html = "<!DOCTYPE html><title>Warning</title><a id='go' href='\(ThreatWarningLink.continueURL(bypassing: originalURL))'>go</a>"
            return "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString()
        }
        // `localhost` is the threatened host; the other server stays on
        // 127.0.0.1 and is never warned about.
        WebKitEngine.updateThreatBlocking(domains: ["localhost"], profileSettings: ["private": EngineProfileThreatSettings(enabled: true)])
    }

    override func tearDownWithError() throws {
        WebKitEngine.updateThreatBlocking(domains: [], profileSettings: [:])
        try super.tearDownWithError()
    }

    private func showWarning(for url: String) {
        tab.loadURL(url)
        waitUntil("warning shown") { recorder.events.contains("title:Warning") }
    }

    private func follow(_ href: String) throws {
        _ = try callJS("location.href = href; return true;", arguments: ["href": href])
    }

    func testDoctoredContinueTargetIsIgnored() throws {
        let risky = "http://localhost:\(other.port)/risky"
        showWarning(for: risky)
        try follow(ThreatWarningLink.continueURL(bypassing: "http://localhost:\(other.port)/elsewhere"))
        settle(0.5)
        XCTAssertFalse(recorder.events.contains("title:Elsewhere"))
        XCTAssertTrue(WebKitEngine.shouldWarn(host: "localhost", profileName: "private"), "a doctored link must not record a bypass")
    }

    func testExactContinueTargetProceedsOnce() throws {
        let risky = "http://localhost:\(other.port)/risky"
        showWarning(for: risky)
        let link = try XCTUnwrap(callJS("return document.getElementById('go').href;") as? String)
        try follow(link)
        waitUntil("original page loads") { recorder.events.contains("title:Risky") }
    }

    func testContinueLinkOnAnOrdinaryPageIsIgnored() throws {
        loadAndWaitForCommit(server.url("/elsewhere"))
        try follow(ThreatWarningLink.continueURL(bypassing: "http://localhost:\(other.port)/risky"))
        settle(0.5)
        XCTAssertTrue(WebKitEngine.shouldWarn(host: "localhost", profileName: "private"))
    }
}
