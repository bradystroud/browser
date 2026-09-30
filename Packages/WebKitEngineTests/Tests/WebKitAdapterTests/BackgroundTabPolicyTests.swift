import AppKit
import WebKit
import XCTest
@testable import WebKitAdapter

@available(macOS 14.0, *)
final class BackgroundTabPolicyTests: WebKitTabTestCase {
    override func tearDownWithError() throws {
        WebKitEngine.setBackgroundTabPolicy(.balanced)
        try super.tearDownWithError()
    }

    func testChangeReachesAnAlreadyOpenTab() {
        WebKitEngine.setBackgroundTabPolicy(.keepReady)
        XCTAssertEqual(tab.webView.configuration.preferences.inactiveSchedulingPolicy, .none)

        WebKitEngine.setBackgroundTabPolicy(.saveMemory)
        XCTAssertEqual(tab.webView.configuration.preferences.inactiveSchedulingPolicy, .suspend)
    }

    func testNewTabStartsWithTheCurrentPolicy() throws {
        WebKitEngine.setBackgroundTabPolicy(.balanced)
        let hostView = try XCTUnwrap(window.contentView)
        let second = try XCTUnwrap(WebKitEngine.createPrivateTab(hostView: hostView, initialURL: "") as? WebKitTab)
        defer { second.close() }

        XCTAssertEqual(second.webView.configuration.preferences.inactiveSchedulingPolicy, .throttle)
    }
}
