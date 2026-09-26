import XCTest
@testable import WebKitAdapter

/// EmailFieldDetectionScript's messages on the WebKit engine: a focused
/// email field in the main frame reaches native with a main-frame source the
/// policy accepts, and nothing an iframe sends under the same type gets past
/// PageMessagePolicy.
final class EmailFieldMessageTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/signin": .html("""
                <!DOCTYPE html><title>Sign in</title>
                <form><input type="email" name="loginfmt" id="main"></form>
                <iframe id="child" src="/embedded"></iframe>
                """),
            "/embedded": .html("""
                <!DOCTYPE html><title>Embedded</title>
                <input type="email" id="inner">
                """),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        recorder.onPageMessage = { [weak self] _, requestId in
            DispatchQueue.main.async {
                self?.tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")
            }
        }
        loadAndWaitForCommit(server.url("/signin"))
        waitUntil("iframe loaded") {
            ((try? callJS("""
                const w = document.getElementById('child').contentWindow;
                return !!(w && w.document.readyState === 'complete' && w.document.getElementById('inner'));
                """)) as? Bool) == true
        }
    }

    private var tabState: PageMessageTabState {
        PageMessageTabState(engineURL: server.url("/signin"), isShowingStartPage: false)
    }

    private func messages(ofType type: String) -> [(request: String, requestId: Int64, source: PageMessageSource)] {
        recorder.pageMessages.filter { $0.request.contains("\"type\":\"\(type)\"") }
    }

    func testMainFrameFocusIsReportedAndAllowed() throws {
        tab.executeJavaScript(EmailFieldDetectionScript.source)
        _ = try callJS("""
            const el = document.getElementById('main');
            el.value = 'alex@contoso';
            el.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
            return true;
            """)
        waitUntil("focus message arrives") { !messages(ofType: "emailFieldFocused").isEmpty }
        let message = try XCTUnwrap(messages(ofType: "emailFieldFocused").first)
        XCTAssertTrue(message.source.isMainFrame)
        XCTAssertTrue(message.request.contains("\"value\":\"alex@contoso\""))
        XCTAssertEqual(PageMessagePolicy.evaluate(type: "emailFieldFocused", source: message.source, tab: tabState),
                       .allow(origin: WebOrigin(urlString: server.url("/"))))
    }

    func testIframeNeverGetsThrough() throws {
        _ = try callJS("""
            const w = document.getElementById('child').contentWindow;
            // The script itself refuses to run in a subframe...
            w.eval(script);
            const el = w.document.getElementById('inner');
            el.dispatchEvent(new w.FocusEvent('focusin', { bubbles: true }));
            // ...and a hostile iframe sending the message by hand is still
            // identified as a subframe by the engine.
            w.cefQuery({ request: JSON.stringify({ type: 'emailFieldFocused', value: 'x@y.z' }),
                         onSuccess: function() {}, onFailure: function() {} });
            return true;
            """, arguments: ["script": EmailFieldDetectionScript.source])
        waitUntil("hand-sent message arrives") { !messages(ofType: "emailFieldFocused").isEmpty }
        settle(0.3)
        let received = messages(ofType: "emailFieldFocused")
        XCTAssertEqual(received.count, 1, "only the hand-sent message; the script stays silent in a subframe")
        let message = try XCTUnwrap(received.first)
        XCTAssertFalse(message.source.isMainFrame)
        guard case .reject = PageMessagePolicy.evaluate(type: "emailFieldFocused", source: message.source, tab: tabState) else {
            return XCTFail("an iframe's email-field message passed the policy")
        }
    }
}
