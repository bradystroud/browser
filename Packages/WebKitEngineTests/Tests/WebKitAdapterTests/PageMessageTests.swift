import XCTest
@testable import WebKitAdapter

/// window.cefQuery / cefQueryCancel on WebKit -- the channel every CEF-era
/// page script (password capture, autofill, reading list, start page) uses.
final class PageMessageTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/frames": .html("""
                <!DOCTYPE html><title>Frames</title>
                <iframe id="child" src="/child"></iframe>
                """),
            "/child": .html("<!DOCTYPE html><title>Child</title><p>child frame</p>"),
        ]
    }

    private static let queryScript = """
    return await new Promise((resolve) => {
      target.cefQuery({
        request: request,
        onSuccess: (response) => resolve("success:" + response),
        onFailure: (code, message) => resolve("failure:" + code + ":" + message),
      });
    });
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Answer asynchronously, as the app's real handlers do.
        recorder.onPageMessage = { [weak self] request, requestId in
            DispatchQueue.main.async {
                guard let self, request != "hold" else { return }
                if request.hasPrefix("fail") {
                    self.tab.respondToPageMessage(requestId: requestId, success: false, response: "nope")
                } else {
                    self.tab.respondToPageMessage(requestId: requestId, success: true, response: "echo:" + request)
                }
            }
        }
        loadAndWaitForCommit(server.url("/frames"))
        waitUntil("child frame loaded") {
            ((try? callJS("""
                const w = document.getElementById('child').contentWindow;
                return !!(w && w.document.readyState === 'complete' && w.document.title === 'Child');
                """)) as? Bool) == true
        }
    }

    func testCefQueryIsInstalledInMainFrameAndIframe() throws {
        let types = try XCTUnwrap(callJS("""
            const w = document.getElementById('child').contentWindow;
            return [typeof window.cefQuery, typeof window.cefQueryCancel,
                    typeof w.cefQuery, typeof w.cefQueryCancel,
                    w.cefQuery !== window.cefQuery];
            """) as? [Any])
        XCTAssertEqual(types.prefix(4).compactMap { $0 as? String }, ["function", "function", "function", "function"])
        XCTAssertEqual(types.last as? Bool, true, "each frame gets its own binding, as CEF's renderer router gives each V8 context")
    }

    func testCefQueryIsReadOnly() throws {
        let stillNative = try callJS("""
            try { window.cefQuery = function() {}; } catch (e) {}
            try { delete window.cefQuery; } catch (e) {}
            return typeof window.cefQuery === 'function' && window.cefQuery.toString().indexOf('persistent') !== -1;
            """) as? Bool
        XCTAssertEqual(stillNative, true)
    }

    func testRoundTripFromMainFrame() throws {
        let result = try callJS(Self.queryScript.replacingOccurrences(of: "target.", with: "window."),
                                arguments: ["request": "ping"]) as? String
        XCTAssertEqual(result, "success:echo:ping")
        XCTAssertEqual(recorder.pageMessages.map(\.request), ["ping"])
    }

    func testRoundTripFromIframe() throws {
        let script = "const target = document.getElementById('child').contentWindow;\n" + Self.queryScript
        let result = try callJS(script, arguments: ["request": "from-iframe"]) as? String
        XCTAssertEqual(result, "success:echo:from-iframe")
        XCTAssertEqual(recorder.pageMessages.map(\.request), ["from-iframe"])
    }

    /// BRWPageMessageRouter reports every native failure as code 0.
    func testFailureReachesOnFailureWithCodeZero() throws {
        let result = try callJS(Self.queryScript.replacingOccurrences(of: "target.", with: "window."),
                                arguments: ["request": "fail-please"]) as? String
        XCTAssertEqual(result, "failure:0:nope")
    }

    func testCancelSuppressesCallbacks() throws {
        _ = try callJS("""
            window.__cancelled = [];
            const id = window.cefQuery({
              request: "hold",
              onSuccess: (r) => window.__cancelled.push("success:" + r),
              onFailure: (c, m) => window.__cancelled.push("failure:" + c),
            });
            window.cefQueryCancel(id);
            return id;
            """)
        waitUntil("held query reaches native") { recorder.pageMessages.contains { $0.request == "hold" } }
        let held = try XCTUnwrap(recorder.pageMessages.first { $0.request == "hold" })
        tab.respondToPageMessage(requestId: held.requestId, success: true, response: "too late")

        // Replies travel in order over one IPC connection, so once a later
        // query has resolved, the cancelled one's reply has been delivered too.
        let later = try callJS(Self.queryScript.replacingOccurrences(of: "target.", with: "window."),
                               arguments: ["request": "after"]) as? String
        XCTAssertEqual(later, "success:echo:after")
        let cancelled = try XCTUnwrap(callJS("return window.__cancelled") as? [Any])
        XCTAssertTrue(cancelled.isEmpty, "a cancelled query must never call back: \(cancelled)")
    }

    /// A closing tab fails whatever it still owes (CEF's kCanceledErrorCode),
    /// rather than leaking WebKit's reply blocks.
    func testClosingTabFailsOutstandingQueries() throws {
        _ = try callJS("""
            window.__closed = [];
            window.cefQuery({
              request: "hold",
              onSuccess: (r) => window.__closed.push("success:" + r),
              onFailure: (c, m) => window.__closed.push("failure:" + c + ":" + m),
            });
            return true;
            """)
        waitUntil("held query reaches native") { recorder.pageMessages.contains { $0.request == "hold" } }
        tab.close()
        var outcome: [Any]?
        waitUntil("page sees the cancellation") {
            tab.webView.evaluateJavaScript("window.__closed") { value, _ in outcome = value as? [Any] }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            return (outcome?.count ?? 0) > 0
        }
        XCTAssertEqual(outcome?.first as? String, "failure:-1:The query has been canceled")
    }
}
