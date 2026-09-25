import AppKit
import WebKit
import XCTest
@testable import WebKitAdapter

/// Base class for tests that drive a real WebKitTab: one private-browsing tab
/// (non-persistent data store, so nothing is written to disk) hosted in an
/// offscreen window that is never ordered on screen, plus a local HTTP server
/// serving whatever `routes` returns.
///
/// Everything runs on the main thread; waits spin the main run loop so
/// WebKit's delegate callbacks and KVO can arrive.
@MainActor
class WebKitTabTestCase: XCTestCase {
    var server: LocalHTTPServer!
    var window: NSWindow!
    var tab: WebKitTab!
    var recorder: RecordingTabDelegate!

    /// Overridden per test class.
    func routes() -> [String: LocalHTTPServer.Response] { [:] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        server = try LocalHTTPServer(routes: routes())
        try server.start()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostView = try XCTUnwrap(window.contentView)
        // An empty initial URL loads nothing, so no callback can fire before
        // the recorder is attached.
        tab = try XCTUnwrap(WebKitEngine.createPrivateTab(hostView: hostView, initialURL: "") as? WebKitTab)
        recorder = RecordingTabDelegate()
        tab.delegate = recorder
    }

    override func tearDownWithError() throws {
        tab?.close()
        tab = nil
        window?.close()
        window = nil
        server?.stop()
        server = nil
        recorder = nil
        try super.tearDownWithError()
    }

    // MARK: - Waiting

    /// Spins the main run loop until `condition` holds, failing after
    /// `timeout` seconds.
    @discardableResult
    func waitUntil(_ description: String, timeout: TimeInterval = 10,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out after \(timeout)s waiting for: \(description). Events: \(recorder?.events ?? [])", file: file, line: line)
                return false
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Lets the run loop turn for `seconds`, for asserting that something
    /// does *not* happen.
    func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Loads `url` and waits for its visit to be reported.
    func loadAndWaitForCommit(_ url: String, file: StaticString = #filePath, line: UInt = #line) {
        tab.loadURL(url)
        waitUntil("commit of \(url)", file: file, line: line) {
            recorder.events.contains("commit:\(url)")
        }
    }

    /// Runs `body` as an async function body in the page content world (the
    /// world every page script, and the cefQuery shim, lives in) and returns
    /// its result.
    func callJS(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval = 10,
                file: StaticString = #filePath, line: UInt = #line) throws -> Any? {
        var outcome: Result<Any, Error>?
        tab.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { outcome = $0 }
        waitUntil("JavaScript result", timeout: timeout, file: file, line: line) { outcome != nil }
        switch outcome {
        case .success(let value): return value is NSNull ? nil : value
        case .failure(let error): throw error
        case nil: return nil
        }
    }
}
