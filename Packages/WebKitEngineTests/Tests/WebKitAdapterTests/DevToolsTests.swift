import AppKit
import WebKit
import XCTest
@testable import WebKitAdapter

/// The in-app Web Inspector, docked into an app-owned container through the
/// private `_WKInspector` SPI. Skipped where that SPI is missing.
final class DevToolsTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        ["/page": .html("<title>DevTools</title><body><p id=target style='margin:40px'>Inspect me</p></body>")]
    }

    private var container: NSView!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(WebKitInspector.isAvailable, "_WKInspector SPI unavailable on this macOS")
        let contentView = try XCTUnwrap(window.contentView)
        container = NSView(frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: 300))
        contentView.addSubview(container)
    }

    private var frontend: WKWebView? { WebKitInspector.inspector(of: tab.webView)?.inspectorWebView }

    private func waitForFrontendInContainer(file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("inspector frontend docked into the container", file: file, line: line) {
            guard let frontend = self.frontend else { return false }
            return frontend.isDescendant(of: self.container) && frontend.frame.size == self.container.bounds.size
        }
    }

    func testDockedOpenAndCloseRoundTrip() throws {
        try XCTSkipUnless(WebKitInspector.canDockIntoContainer, "attachment-view SPI unavailable")
        loadAndWaitForCommit(server.url("/page"))
        XCTAssertFalse(tab.isDevToolsOpen)

        tab.showDevTools(panel: .default, dockSide: .bottom, in: container)
        waitUntil("devtools open") { self.tab.isDevToolsOpen && self.recorder.events.contains("devToolsOpen") }
        waitForFrontendInContainer()
        // The page itself is never resized by WebKit's docking arithmetic.
        XCTAssertEqual(tab.webView.frame, window.contentView?.bounds)
        XCTAssertTrue(recorder.events(named: "devToolsDockSide").isEmpty, "a requested placement is not a user dock-side choice")

        tab.closeDevTools()
        waitUntil("devtools closed") { !self.tab.isDevToolsOpen && self.recorder.events.contains("devToolsClose") }
        XCTAssertFalse(frontend?.isDescendant(of: container) ?? false)
    }

    /// WebKit's own Inspect Element opens the inspector without the app
    /// asking; the delegate hears first and can claim it for its container.
    func testEngineInitiatedOpenCanBeClaimed() throws {
        try XCTSkipUnless(WebKitInspector.canDockIntoContainer, "attachment-view SPI unavailable")
        loadAndWaitForCommit(server.url("/page"))
        recorder.onDevToolsOpen = { [unowned self] in
            tab.showDevTools(panel: .default, dockSide: .right, in: container)
        }
        // What the context menu's Inspect Element ends up calling.
        WebKitInspector.inspector(of: tab.webView)?.show()
        waitForFrontendInContainer()
        XCTAssertEqual(recorder.events(named: "devToolsOpen").count, 1)
    }

    /// The frontend's own dock buttons move it; the app hears the new side.
    func testDockSideChosenInsideTheToolsIsReported() throws {
        try XCTSkipUnless(WebKitInspector.canDockIntoContainer, "attachment-view SPI unavailable")
        loadAndWaitForCommit(server.url("/page"))
        tab.showDevTools(panel: .default, dockSide: .bottom, in: container)
        waitForFrontendInContainer()
        // Let the requested side settle before acting as the user.
        settle(1)
        recorder.reset()
        frontend?.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('left')", completionHandler: nil)
        waitUntil("left dock side reported") { self.recorder.events.contains("devToolsDockSide:left") }
        waitForFrontendInContainer()
    }

    /// inspectElement(at:) selects the element under the point in Elements.
    /// (A separate-window open is not tested here: it would put a real
    /// window on screen.)
    func testInspectElementAtPoint() throws {
        try XCTSkipUnless(WebKitInspector.canDockIntoContainer, "attachment-view SPI unavailable")
        loadAndWaitForCommit(server.url("/page"))
        let rect = try XCTUnwrap(callJS("""
            const r = document.getElementById("target").getBoundingClientRect();
            return [r.left + 5, r.top + 5];
            """) as? [Double])
        let viewY = tab.webView.isFlipped ? rect[1] : tab.webView.bounds.height - rect[1]
        tab.showDevTools(panel: .elements, dockSide: .bottom, in: container)
        tab.inspectElement(at: NSPoint(x: rect[0], y: viewY))
        var selectedId: String?
        waitUntil("#target selected in Elements") {
            self.frontend?.evaluateJavaScript("WI.domManager.inspectedNode && WI.domManager.inspectedNode.getAttribute('id')") { value, _ in
                selectedId = value as? String
            }
            return selectedId == "target"
        }
    }
}
