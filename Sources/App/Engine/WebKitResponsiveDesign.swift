import AppKit
import ObjectiveC
import WebKit

/// Responsive Design Mode on the WebKit engine -- the closest WKWebView gets
/// to CEF's Emulation.setDeviceMetricsOverride, built from private WKWebView
/// SPI that Safari's own Responsive Design Mode rests on. Every selector is
/// looked up at runtime and its type encoding checked before use, so a macOS
/// that drops or changes one only makes `isAvailable` false; nothing private
/// is linked.
///
/// How each part of the CEF override is reproduced:
/// - Viewport: the web view lays out at a fixed width x height CSS px
///   (`_setLayoutMode:` fixed-size + `_setFixedLayoutSize:`), and its frame
///   shrinks to that size, centred in the tab's content area. The window's
///   own background shows around it. An opaque backdrop view added to the
///   tab's host view blanks the window's glass toolbar and tab strip.
/// - Zoom to fit: when the device is larger than the content area,
///   `_setViewScale:` draws the page smaller and the frame shrinks with it,
///   the way Chrome's device toolbar zooms a phone to fit. Layout, and so
///   `innerWidth`, stays at the device's CSS size.
/// - Device scale factor: `_setOverrideDeviceScaleFactor:`, which is what
///   `devicePixelRatio`, `srcset` and resolution media queries see.
/// - Mobile: a mobile Safari user agent (iPhone, or iPad for a tablet-sized
///   preset). WebKit on macOS has no meta-viewport handling and no touch
///   event support at all, so neither can be emulated -- see the limits below.
///
/// Every setting lives on the web view, not the document, so it survives
/// navigation, reload and a cross-site web-process swap. `restore()` puts
/// back exactly what was there before the first `apply`, whatever preset
/// switches happened in between.
///
/// Not reproducible here, unlike Chrome's device mode: touch events and
/// `(pointer: coarse)`/`(hover: none)` (macOS WebKit has no touch support),
/// `<meta name="viewport">` (ignored by macOS WebKit, so a page asking for a
/// 980px layout still gets the device width), and `navigator.platform`/
/// `maxTouchPoints`, which still describe the Mac.
final class WebKitResponsiveDesign {
    /// True when every SPI this needs exists with the expected signature.
    static var isAvailable: Bool { SPI.shared != nil }

    /// Gap kept between the device frame and the edge of the content area
    /// when the device has to be scaled down to fit.
    static let fitMargin: CGFloat = 16

    /// What the web view looked like before responsive design mode, restored
    /// verbatim on exit.
    struct SavedState: Equatable {
        var frame: NSRect
        var superviewSize: NSSize?
        var autoresizingMask: NSView.AutoresizingMask
        var customUserAgent: String?
        var overrideDeviceScaleFactor: Double
        var viewScale: Double
        var layoutMode: UInt
        var fixedLayoutSize: CGSize
    }

    struct Metrics: Equatable {
        var width: Int
        var height: Int
        var deviceScaleFactor: Double
        var mobile: Bool
    }

    private(set) weak var webView: WKWebView?
    let savedState: SavedState
    private(set) var metrics: Metrics?
    private weak var host: NSView?
    private var observers: [NSObjectProtocol] = []
    private var isApplying = false

    /// Captures the web view's current state; nothing changes until `apply`.
    /// Nil when the SPI is missing.
    init?(webView: WKWebView) {
        guard let spi = SPI.shared else { return nil }
        self.webView = webView
        savedState = SavedState(
            frame: webView.frame,
            superviewSize: webView.superview?.bounds.size,
            autoresizingMask: webView.autoresizingMask,
            customUserAgent: webView.customUserAgent,
            overrideDeviceScaleFactor: spi.overrideDeviceScaleFactor(webView),
            viewScale: spi.viewScale(webView),
            layoutMode: spi.layoutMode(webView),
            fixedLayoutSize: spi.fixedLayoutSize(webView))
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func apply(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        guard let webView, let spi = SPI.shared else { return }
        let metrics = Metrics(width: max(width, 1), height: max(height, 1),
                              deviceScaleFactor: deviceScaleFactor, mobile: mobile)
        self.metrics = metrics

        spi.setLayoutMode(webView, SPI.fixedSizeLayoutMode)
        spi.setFixedLayoutSize(webView, CGSize(width: metrics.width, height: metrics.height))
        webView.customUserAgent = mobile
            ? Self.mobileUserAgent(width: metrics.width, height: metrics.height)
            : savedState.customUserAgent
        layOut()
    }

    /// Puts the web view back exactly as it was.
    func restore() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        metrics = nil
        guard let webView, let spi = SPI.shared else { return }

        spi.setViewScale(webView, savedState.viewScale)
        spi.setFixedLayoutSize(webView, savedState.fixedLayoutSize)
        spi.setLayoutMode(webView, savedState.layoutMode)
        spi.setOverrideDeviceScaleFactor(webView, savedState.overrideDeviceScaleFactor)
        webView.customUserAgent = savedState.customUserAgent

        isApplying = true
        webView.autoresizingMask = savedState.autoresizingMask
        webView.frame = savedState.frame
        // The content area may have been resized while the mode was on; let
        // the original autoresizing rules carry the old frame to the new size.
        if let oldSize = savedState.superviewSize, let superview = webView.superview, superview.bounds.size != oldSize {
            webView.resize(withOldSuperviewSize: oldSize)
        }
        isApplying = false
    }

    /// Where a device of `deviceSize` CSS px goes inside `bounds`: centred,
    /// and scaled down (never up) to leave `margin` all round when it would
    /// not otherwise fit.
    static func fittedLayout(deviceSize: CGSize, in bounds: NSRect, margin: CGFloat = fitMargin) -> (frame: NSRect, scale: CGFloat) {
        let availableWidth = bounds.width - margin * 2
        let availableHeight = bounds.height - margin * 2
        var scale: CGFloat = 1
        if deviceSize.width > bounds.width || deviceSize.height > bounds.height {
            scale = min(availableWidth / deviceSize.width, availableHeight / deviceSize.height)
        }
        // A collapsed content area (a window mid-setup) must not reach
        // _setViewScale:, which raises on anything but a positive number.
        scale = min(1, max(scale, 0.05))
        var size = deviceSize
        if scale < 1 {
            (size, scale) = pixelExactScale(deviceSize: deviceSize, approximately: scale)
        }
        let origin = NSPoint(x: (bounds.midX - size.width / 2).rounded(),
                             y: (bounds.midY - size.height / 2).rounded())
        return (NSRect(origin: origin, size: size), scale)
    }

    /// WebKit truncates the view to whole points and then truncates the
    /// view size divided by the view scale again to get the page's viewport,
    /// so a naive scale reports a viewport a CSS px off the device's. This
    /// picks whole-point frame dimensions and a scale near `approximate` for
    /// which both divisions land inside [device size, device size + 1), aiming
    /// for the middle of that window so float error cannot tip it either way.
    static func pixelExactScale(deviceSize: CGSize, approximately approximate: CGFloat) -> (size: NSSize, scale: CGFloat) {
        let width = deviceSize.width, height = deviceSize.height
        let startWidth = max((width * approximate).rounded(.down), 1)
        for frameWidth in stride(from: startWidth, through: max(startWidth - 100, 1), by: -1) {
            let base = (height * frameWidth / width).rounded(.down)
            for frameHeight in [base, base + 1, base - 1] where frameHeight >= 1 {
                let low = max(frameWidth / (width + 1), frameHeight / (height + 1))
                let high = min(frameWidth / width, frameHeight / height)
                if low < high {
                    return (NSSize(width: frameWidth, height: frameHeight), (low + high) / 2)
                }
            }
        }
        return (NSSize(width: (width * approximate).rounded(.up), height: (height * approximate).rounded(.up)), approximate)
    }

    /// Frozen at 18_6 because iOS Safari stopped tracking the OS version in
    /// its user agent from iOS 26 on. The Safari version follows the macOS
    /// user agent this app already sends.
    static func mobileUserAgent(width: Int, height: Int) -> String {
        let version = SafariUserAgent.applicationName
            .split(separator: " ").first { $0.hasPrefix("Version/") }
            .map(String.init) ?? "Version/18.6"
        let device = min(width, height) >= 600 ? "iPad; CPU OS 18_6 like Mac OS X" : "iPhone; CPU iPhone OS 18_6 like Mac OS X"
        return "Mozilla/5.0 (\(device)) AppleWebKit/605.1.15 (KHTML, like Gecko) \(version) Mobile/15E148 Safari/604.1"
    }

    // MARK: - Layout

    private func layOut() {
        guard let webView, let metrics, let spi = SPI.shared, let superview = webView.superview else { return }
        if host !== superview { attach(to: superview) }

        let layout = Self.fittedLayout(deviceSize: CGSize(width: metrics.width, height: metrics.height), in: superview.bounds)
        isApplying = true
        spi.setViewScale(webView, Double(layout.scale))
        // WebKit multiplies the view scale into devicePixelRatio, so a phone
        // zoomed to fit would report a fractional ratio unless divided back out.
        if metrics.deviceScaleFactor > 0 {
            spi.setOverrideDeviceScaleFactor(webView, metrics.deviceScaleFactor / Double(layout.scale))
        } else {
            spi.setOverrideDeviceScaleFactor(webView, savedState.overrideDeviceScaleFactor)
        }
        webView.autoresizingMask = []
        webView.frame = layout.frame
        isApplying = false
    }

    private func attach(to superview: NSView) {
        guard let webView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        host = superview

        let relayout: (Notification) -> Void = { [weak self] _ in
            guard let self, !self.isApplying else { return }
            self.layOut()
        }
        // The content area resizes with the window; the web view's own frame
        // is reset when a tab re-attaches it to a host.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: superview, queue: .main, using: relayout))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: webView, queue: .main, using: relayout))
    }

    // MARK: - SPI

    /// The private WKWebView methods, resolved once. Nil unless every one
    /// exists with the signature this file calls it with.
    struct SPI {
        /// _WKLayoutModeFixedSize: lay out at _fixedLayoutSize whatever the
        /// view's own size.
        static let fixedSizeLayoutMode: UInt = 1

        typealias DoubleGetter = @convention(c) (AnyObject, Selector) -> Double
        typealias DoubleSetter = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias UIntGetter = @convention(c) (AnyObject, Selector) -> UInt
        typealias UIntSetter = @convention(c) (AnyObject, Selector, UInt) -> Void
        typealias SizeGetter = @convention(c) (AnyObject, Selector) -> CGSize
        typealias SizeSetter = @convention(c) (AnyObject, Selector, CGSize) -> Void

        private let getDeviceScaleFactor: DoubleGetter
        private let putDeviceScaleFactor: DoubleSetter
        private let getViewScale: DoubleGetter
        private let putViewScale: DoubleSetter
        private let getLayoutMode: UIntGetter
        private let putLayoutMode: UIntSetter
        private let getFixedLayoutSize: SizeGetter
        private let putFixedLayoutSize: SizeSetter

        static let shared: SPI? = SPI()

        private static let names = (
            getDeviceScaleFactor: "_overrideDeviceScaleFactor", putDeviceScaleFactor: "_setOverrideDeviceScaleFactor:",
            getViewScale: "_viewScale", putViewScale: "_setViewScale:",
            getLayoutMode: "_layoutMode", putLayoutMode: "_setLayoutMode:",
            getFixedLayoutSize: "_fixedLayoutSize", putFixedLayoutSize: "_setFixedLayoutSize:")

        private init?() {
            let sizeEncoding = "{CGSize=dd}"
            guard
                let a = Self.method(Self.names.getDeviceScaleFactor, returns: "d", as: DoubleGetter.self),
                let b = Self.method(Self.names.putDeviceScaleFactor, returns: "v", argument: "d", as: DoubleSetter.self),
                let c = Self.method(Self.names.getViewScale, returns: "d", as: DoubleGetter.self),
                let d = Self.method(Self.names.putViewScale, returns: "v", argument: "d", as: DoubleSetter.self),
                let e = Self.method(Self.names.getLayoutMode, returns: "Q", as: UIntGetter.self),
                let f = Self.method(Self.names.putLayoutMode, returns: "v", argument: "Q", as: UIntSetter.self),
                let g = Self.method(Self.names.getFixedLayoutSize, returns: sizeEncoding, as: SizeGetter.self),
                let h = Self.method(Self.names.putFixedLayoutSize, returns: "v", argument: sizeEncoding, as: SizeSetter.self)
            else { return nil }
            (getDeviceScaleFactor, putDeviceScaleFactor, getViewScale, putViewScale) = (a, b, c, d)
            (getLayoutMode, putLayoutMode, getFixedLayoutSize, putFixedLayoutSize) = (e, f, g, h)
        }

        private static func method<T>(_ name: String, returns: String, argument: String? = nil, as type: T.Type) -> T? {
            guard let method = class_getInstanceMethod(WKWebView.self, NSSelectorFromString(name)) else {
                NSLog("Browser: WebKit responsive design SPI missing: %@", name)
                return nil
            }
            let returnType = String(cString: method_copyReturnType(method))
            let expectedArguments = argument == nil ? 2 : 3
            var matches = returnType == returns && method_getNumberOfArguments(method) == UInt32(expectedArguments)
            if matches, let argument, let raw = method_copyArgumentType(method, 2) {
                matches = String(cString: raw) == argument
                free(raw)
            }
            guard matches else {
                NSLog("Browser: WebKit responsive design SPI has an unexpected signature: %@", name)
                return nil
            }
            return unsafeBitCast(method_getImplementation(method), to: type)
        }

        func overrideDeviceScaleFactor(_ webView: WKWebView) -> Double {
            getDeviceScaleFactor(webView, NSSelectorFromString(Self.names.getDeviceScaleFactor))
        }
        func setOverrideDeviceScaleFactor(_ webView: WKWebView, _ value: Double) {
            putDeviceScaleFactor(webView, NSSelectorFromString(Self.names.putDeviceScaleFactor), value)
        }
        func viewScale(_ webView: WKWebView) -> Double {
            getViewScale(webView, NSSelectorFromString(Self.names.getViewScale))
        }
        /// _setViewScale: raises on anything but a positive, finite number.
        func setViewScale(_ webView: WKWebView, _ value: Double) {
            guard value > 0, value.isFinite else { return }
            putViewScale(webView, NSSelectorFromString(Self.names.putViewScale), value)
        }
        func layoutMode(_ webView: WKWebView) -> UInt {
            getLayoutMode(webView, NSSelectorFromString(Self.names.getLayoutMode))
        }
        func setLayoutMode(_ webView: WKWebView, _ value: UInt) {
            putLayoutMode(webView, NSSelectorFromString(Self.names.putLayoutMode), value)
        }
        func fixedLayoutSize(_ webView: WKWebView) -> CGSize {
            getFixedLayoutSize(webView, NSSelectorFromString(Self.names.getFixedLayoutSize))
        }
        func setFixedLayoutSize(_ webView: WKWebView, _ value: CGSize) {
            putFixedLayoutSize(webView, NSSelectorFromString(Self.names.putFixedLayoutSize), value)
        }
    }
}
