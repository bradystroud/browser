import AppKit
import WebKit
import XCTest
@testable import WebKitAdapter

final class ResponsiveDesignTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/metrics": .html("""
                <!DOCTYPE html><title>Metrics</title>
                <meta name="viewport" content="width=device-width">
                <p>metrics</p>
                """),
        ]
    }

    private struct PageMetrics: Equatable {
        var innerWidth: Int
        var innerHeight: Int
        var devicePixelRatio: Double
        var userAgent: String
    }

    private func pageMetrics(file: StaticString = #filePath, line: UInt = #line) throws -> PageMetrics {
        let value = try callJS("return [innerWidth, innerHeight, devicePixelRatio, navigator.userAgent];", file: file, line: line)
        let parts = try XCTUnwrap(value as? [Any], file: file, line: line)
        return PageMetrics(
            innerWidth: (parts[0] as? NSNumber)?.intValue ?? -1,
            innerHeight: (parts[1] as? NSNumber)?.intValue ?? -1,
            devicePixelRatio: (parts[2] as? NSNumber)?.doubleValue ?? -1,
            userAgent: parts[3] as? String ?? "")
    }

    /// Waits for the page's own view of the viewport to catch up, since the
    /// layout and scale-factor changes reach the web process asynchronously.
    private func waitForMetrics(file: StaticString = #filePath, line: UInt = #line,
                                _ condition: (PageMetrics) -> Bool) throws -> PageMetrics {
        var last: PageMetrics?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let current = try pageMetrics(file: file, line: line)
            last = current
            if condition(current) { return current }
            settle(0.05)
        }
        XCTFail("Page metrics never matched; last: \(String(describing: last))", file: file, line: line)
        return try XCTUnwrap(last, file: file, line: line)
    }

    private var hostView: NSView { window.contentView! }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(WebKitResponsiveDesign.isAvailable, "WKWebView responsive design SPI is missing on this macOS")
        loadAndWaitForCommit(server.url("/metrics"))
    }

    func testPhonePresetSetsViewportScaleFactorAndMobileUserAgent() throws {
        tab.setResponsiveDesignMode(width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
        tab.reload()
        let metrics = try waitForMetrics { $0.innerWidth == 390 && $0.userAgent.contains("iPhone") }
        XCTAssertEqual(metrics.innerHeight, 844)
        XCTAssertEqual(metrics.devicePixelRatio, 3)
        XCTAssertTrue(metrics.userAgent.contains("Mobile/"), metrics.userAgent)
    }

    func testDeviceIsScaledToFitAndCentred() throws {
        tab.setResponsiveDesignMode(width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
        let frame = tab.webView.frame
        let bounds = hostView.bounds
        // 844pt tall does not fit the 768pt window, so it is scaled down.
        XCTAssertEqual(frame.height, bounds.height - 2 * WebKitResponsiveDesign.fitMargin, accuracy: 1)
        XCTAssertEqual(frame.width / frame.height, 390.0 / 844.0, accuracy: 0.01)
        XCTAssertEqual(frame.midX, bounds.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, bounds.midY, accuracy: 1)
        XCTAssertEqual(hostView.subviews.count, 1, "nothing is added to the host view")

        let metrics = try waitForMetrics { $0.innerWidth == 390 }
        XCTAssertEqual(metrics.innerHeight, 844, "layout keeps the device's CSS size even when drawn smaller")
    }

    func testHeavilyScaledTabletReportsTheExactViewport() throws {
        tab.setResponsiveDesignMode(width: 1024, height: 1366, deviceScaleFactor: 2, mobile: true)
        XCTAssertLessThan(tab.webView.frame.height, 768)
        tab.reload()
        let metrics = try waitForMetrics { $0.innerWidth == 1024 && $0.innerHeight == 1366 && $0.userAgent.contains("iPad") }
        XCTAssertEqual(metrics.devicePixelRatio, 2, accuracy: 0.0001)
    }

    func testSmallDeviceIsNotScaledUp() {
        tab.setResponsiveDesignMode(width: 375, height: 600, deviceScaleFactor: 2, mobile: true)
        XCTAssertEqual(tab.webView.frame.size, NSSize(width: 375, height: 600))
    }

    func testSurvivesReloadAndCrossSiteNavigation() throws {
        tab.setResponsiveDesignMode(width: 375, height: 667, deviceScaleFactor: 2, mobile: true)
        tab.reload()
        _ = try waitForMetrics { $0.innerWidth == 375 && $0.devicePixelRatio == 2 && $0.userAgent.contains("iPhone") }

        // A different host is a different site, which can swap web processes.
        let crossSite = server.url("/metrics").replacingOccurrences(of: "127.0.0.1", with: "localhost")
        tab.loadURL(crossSite)
        waitUntil("cross-site commit") { recorder.events.contains { $0.hasPrefix("commit:") && $0.contains("localhost") } }
        let metrics = try waitForMetrics { $0.innerWidth == 375 }
        XCTAssertEqual(metrics.innerHeight, 667)
        XCTAssertEqual(metrics.devicePixelRatio, 2)
        XCTAssertTrue(metrics.userAgent.contains("iPhone"), metrics.userAgent)
    }

    func testClearRestoresEverything() throws {
        let before = try pageMetrics()
        let frame = tab.webView.frame
        let mask = tab.webView.autoresizingMask
        let userAgent = tab.webView.customUserAgent

        tab.setResponsiveDesignMode(width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
        _ = try waitForMetrics { $0.innerWidth == 390 && $0.devicePixelRatio == 3 }
        tab.clearResponsiveDesignMode()

        XCTAssertNil(tab.responsiveDesign)
        XCTAssertEqual(tab.webView.frame, frame)
        XCTAssertEqual(tab.webView.autoresizingMask, mask)
        XCTAssertEqual(tab.webView.customUserAgent, userAgent)
        tab.reload()
        let after = try waitForMetrics { $0.innerWidth == before.innerWidth && $0.devicePixelRatio == before.devicePixelRatio }
        XCTAssertEqual(after, before)
    }

    func testSwitchingPresetsKeepsTheOriginalStateAndDesktopPresetKeepsUserAgent() throws {
        let userAgent = tab.webView.customUserAgent
        tab.setResponsiveDesignMode(width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
        let saved = try XCTUnwrap(tab.responsiveDesign?.savedState)
        tab.setResponsiveDesignMode(width: 1024, height: 1366, deviceScaleFactor: 2, mobile: true)
        XCTAssertEqual(tab.responsiveDesign?.savedState, saved)
        XCTAssertTrue(tab.webView.customUserAgent?.contains("iPad") == true)

        tab.setResponsiveDesignMode(width: 800, height: 600, deviceScaleFactor: 1, mobile: false)
        XCTAssertEqual(tab.webView.customUserAgent, userAgent, "a non-mobile device keeps the normal user agent")
        _ = try waitForMetrics { $0.innerWidth == 800 && $0.innerHeight == 600 && $0.devicePixelRatio == 1 }

        tab.clearResponsiveDesignMode()
        XCTAssertEqual(tab.webView.frame, saved.frame)
    }

    func testHostResizeRefitsAndClearFollowsTheNewSize() {
        tab.setResponsiveDesignMode(width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
        window.setContentSize(NSSize(width: 1200, height: 1000))
        let bounds = hostView.bounds
        XCTAssertEqual(tab.webView.frame.size, NSSize(width: 390, height: 844), "fits unscaled once the window is tall enough")
        XCTAssertEqual(tab.webView.frame.midX, bounds.midX, accuracy: 1)

        tab.clearResponsiveDesignMode()
        XCTAssertEqual(tab.webView.frame, bounds, "the original fill-the-host autoresizing is carried to the new size")
    }

    func testClearWithoutSetIsHarmless() {
        let frame = tab.webView.frame
        tab.clearResponsiveDesignMode()
        XCTAssertEqual(tab.webView.frame, frame)
        XCTAssertNil(tab.responsiveDesign)
    }

    func testFittedLayout() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 500)
        let fits = WebKitResponsiveDesign.fittedLayout(deviceSize: CGSize(width: 400, height: 300), in: bounds)
        XCTAssertEqual(fits.scale, 1)
        XCTAssertEqual(fits.frame, NSRect(x: 300, y: 100, width: 400, height: 300))

        let tall = WebKitResponsiveDesign.fittedLayout(deviceSize: CGSize(width: 400, height: 936), in: bounds, margin: 16)
        XCTAssertEqual(tall.scale, 0.5, accuracy: 0.001)
        XCTAssertEqual(tall.frame.height, 468, accuracy: 1)
        XCTAssertEqual(tall.frame.midX, 500, accuracy: 1)

        let collapsed = WebKitResponsiveDesign.fittedLayout(deviceSize: CGSize(width: 400, height: 800), in: .zero)
        XCTAssertGreaterThan(collapsed.scale, 0)
    }

    /// The page's viewport is the whole-point frame divided by the scale,
    /// truncated -- it must come out at exactly the device size for every
    /// preset at any window height.
    func testScaledFrameYieldsTheExactDeviceViewport() {
        let devices: [(Int, Int)] = [(375, 667), (390, 844), (430, 932), (744, 1133), (1024, 1366)]
        for (width, height) in devices {
            for hostHeight in stride(from: 300, through: 1400, by: 7) {
                let bounds = NSRect(x: 0, y: 0, width: 1440, height: hostHeight)
                let layout = WebKitResponsiveDesign.fittedLayout(deviceSize: CGSize(width: width, height: height), in: bounds)
                XCTAssertEqual(layout.frame.width, layout.frame.width.rounded(), "\(width)x\(height) in \(hostHeight)")
                XCTAssertEqual(layout.frame.height, layout.frame.height.rounded(), "\(width)x\(height) in \(hostHeight)")
                XCTAssertEqual(Int(layout.frame.width / layout.scale), width, "\(width)x\(height) in \(hostHeight)")
                XCTAssertEqual(Int(layout.frame.height / layout.scale), height, "\(width)x\(height) in \(hostHeight)")
                XCTAssertLessThanOrEqual(layout.frame.height, bounds.height, "\(width)x\(height) in \(hostHeight)")
            }
        }
    }

    func testMobileUserAgentPicksPhoneOrTablet() {
        XCTAssertTrue(WebKitResponsiveDesign.mobileUserAgent(width: 390, height: 844).contains("iPhone"))
        XCTAssertTrue(WebKitResponsiveDesign.mobileUserAgent(width: 744, height: 1133).contains("iPad"))
        XCTAssertTrue(WebKitResponsiveDesign.mobileUserAgent(width: 390, height: 844).contains("Mobile/15E148 Safari/604.1"))
    }
}
