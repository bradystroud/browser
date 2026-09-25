import XCTest
@testable import WebKitAdapter

final class NavigationTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/page": .html("""
                <!DOCTYPE html><html><head><title>Order Test</title>
                <link rel="icon" href="/icon.png"></head>
                <body><p>Hello from the navigation test.</p></body></html>
                """),
            "/after-error": .html("<!DOCTYPE html><title>Recovered</title><p>back</p>"),
        ]
    }

    /// The order the CEF adapter delivers and the shell depends on:
    /// OnBeforeBrowse (will-start) -> progress -> OnLoadStart (did-start-load)
    /// -> favicon -> OnLoadEnd (commit, the history-recording signal).
    /// The title must already be known when the visit is recorded, or history
    /// stores the URL untitled.
    func testNavigationCallbacksArriveInCEFOrder() {
        let url = server.url("/page")
        loadAndWaitForCommit(url)
        let r = recorder!

        guard let willStart = r.firstIndex(of: "willStart"),
              let didStartLoad = r.firstIndex(of: "didStartLoad"),
              let favicon = r.firstIndex(of: "favicon"),
              let title = r.events.firstIndex(of: "title:Order Test"),
              let commit = r.firstIndex(of: "commit") else {
            return XCTFail("missing a lifecycle callback: \(r.events)")
        }
        XCTAssertEqual(r.events[willStart], "willStart:\(url)")
        XCTAssertLessThan(willStart, didStartLoad, "will-start must precede did-start-load: \(r.events)")
        XCTAssertLessThan(didStartLoad, favicon, "\(r.events)")
        XCTAssertLessThan(favicon, commit, "favicon hint must precede the visit: \(r.events)")
        XCTAssertLessThan(title, commit, "title must be known before the visit is reported: \(r.events)")
        XCTAssertEqual(r.events[favicon], "favicon:\(server.url("/icon.png"))")

        let progress = r.events.indices.filter { r.events[$0].hasPrefix("progress:") }
        XCTAssertTrue(progress.contains { $0 > willStart && $0 < commit },
                      "expected at least one progress update between will-start and commit: \(r.events)")

        XCTAssertEqual(r.events(named: "commit"), ["commit:\(url)"], "exactly one visit per navigation")
    }

    /// A navigation that never commits shows the adapter's own error page,
    /// keeps the failing URL as the tab's address, and is not a visit.
    func testUnresolvableHostShowsErrorPageAndReportsNoVisit() throws {
        // .invalid is reserved (RFC 2606) and never resolves.
        let failing = "http://browser-webkit-tests.invalid/"
        tab.loadURL(failing)
        XCTAssertTrue(waitUntil("error page rendered") {
            let text = (try? callJS("return document.body ? document.body.innerText : ''")) as? String ?? ""
            return text.contains("Try Again")
        })
        settle(0.3)

        XCTAssertEqual(recorder.firstIndex(of: "willStart").map { recorder.events[$0] }, "willStart:\(failing)")
        XCTAssertTrue(recorder.events(named: "commit").isEmpty, "an error page is not a visit: \(recorder.events)")
        XCTAssertEqual(tab.webView.url?.absoluteString, failing, "the omnibox keeps pointing at the failing address")
        let heading = try callJS("return document.querySelector('h1').textContent") as? String
        XCTAssertNotNil(heading)
        XCTAssertFalse(heading?.isEmpty ?? true)

        // The next real navigation is reported normally again.
        loadAndWaitForCommit(server.url("/after-error"))
        XCTAssertEqual(recorder.events(named: "commit"), ["commit:\(server.url("/after-error"))"])
    }

    /// Safari's shape, so sites that refuse embedded web views (Google
    /// sign-in) don't treat this browser as one.
    func testUserAgentLooksLikeSafari() throws {
        loadAndWaitForCommit(server.url("/page"))
        let ua = try XCTUnwrap(callJS("return navigator.userAgent") as? String)
        XCTAssertTrue(ua.contains("AppleWebKit/"), ua)
        XCTAssertTrue(ua.contains("Version/"), ua)
        XCTAssertTrue(ua.contains("Safari/"), ua)
        XCTAssertNotNil(ua.range(of: #"Version/[0-9.]+ Safari/[0-9.]+$"#, options: .regularExpression), ua)
    }
}
