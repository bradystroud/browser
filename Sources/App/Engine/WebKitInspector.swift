import AppKit
import ObjectiveC
import WebKit

/// The WebKit engine's in-app Web Inspector, driven through WebKit's private
/// `_WKInspector` SPI (`-[WKWebView _inspector]`). Safari's own attached
/// inspector is this same object.
///
/// Every private selector is looked up at runtime and checked before use --
/// nothing here links against a private symbol, so a macOS that drops or
/// renames the SPI degrades to `isAvailable == false` (and WebKitTab's
/// Safari hand-off sheet) instead of failing at launch. That is also why the
/// SPI is reached through `@objc` protocols cast from `AnyObject` rather than
/// a declared class: the cast is only made after `responds(to:)` has passed.
///
/// Selectors confirmed present on macOS 27 (class_copyMethodList): on
/// WKWebView `_inspector`; on WKPreferences `_setDeveloperExtrasEnabled:`;
/// on `_WKInspector` `show`, `close`, `hide`,
/// `attach`, `detach`, `isVisible`, `isConnected`, `isFront`, `showConsole`,
/// `showResources`, `showMainResourceForFrame:`, `toggleElementSelection`,
/// `isElementSelectionActive`, `togglePageProfiling`, `inspectorWebView`.
/// There is no `isAttached` and no "inspect element at point" -- the closest
/// is element-selection mode, where the next click on the page picks the node.
enum WebKitInspector {
    private static let inspectorGetter = NSSelectorFromString("_inspector")
    private static let developerExtrasSetter = NSSelectorFromString("_setDeveloperExtrasEnabled:")

    /// Selectors the core show/close path cannot work without. Console and
    /// element selection are checked separately, so their absence only
    /// narrows what opens rather than disabling the inspector outright.
    private static let requiredInspectorSelectors = ["show", "close", "attach", "isVisible", "inspectorWebView"]

    /// True when every selector the in-app inspector depends on exists on
    /// this macOS. False means showDevTools falls back to the Safari sheet.
    static let isAvailable: Bool = {
        let missing = missingSelectors()
        if missing.isEmpty {
            NSLog("Browser: WebKit in-app Web Inspector available (_WKInspector SPI present)")
            return true
        }
        NSLog("Browser: WebKit in-app Web Inspector unavailable, falling back to Safari hand-off -- missing SPI: %@",
              missing.joined(separator: ", "))
        return false
    }()

    static var canShowConsole: Bool { isAvailable && inspectorClassResponds(to: "showConsole") }
    static var canSelectElement: Bool {
        isAvailable && inspectorClassResponds(to: "toggleElementSelection")
            && inspectorClassResponds(to: "isElementSelectionActive")
    }

    /// Opens (or brings forward) `webView`'s inspector. The first open for a
    /// web view docks it to the bottom of the page like Safari; after that
    /// WebKit's own remembered attached/detached choice wins, so a user who
    /// undocks it isn't re-docked on every open. Returns false when the SPI
    /// is unavailable, so the caller can fall back.
    @discardableResult
    static func show(for webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        enableDeveloperExtras(for: webView)
        let watcher = WebKitInspectorWatcher.install(on: webView)
        inspector.show()
        if !watcher.hasOpened {
            watcher.hasOpened = true
            // attach() is a no-op when WebKit's canAttach() says the page is
            // too small to share, leaving the inspector in its own window.
            if webView.window != nil, !isAttached(inspector, to: webView) { inspector.attach() }
        }
        return true
    }

    /// Opens the inspector on its Console tab. Falls back to a plain show()
    /// when `showConsole` is missing.
    @discardableResult
    static func showConsole(for webView: WKWebView) -> Bool {
        guard show(for: webView), let inspector = inspector(of: webView) else { return false }
        if canShowConsole { inspector.showConsole?() }
        return true
    }

    /// The closest the SPI gets to "Inspect Element at point": opens the
    /// inspector and turns on element selection, so the next click on the
    /// page selects that node. A point cannot be passed.
    @discardableResult
    static func beginElementSelection(for webView: WKWebView) -> Bool {
        guard show(for: webView), let inspector = inspector(of: webView) else { return false }
        if canSelectElement, inspector.isElementSelectionActive?() != true {
            inspector.toggleElementSelection?()
        }
        return true
    }

    static func close(for webView: WKWebView) {
        guard let inspector = inspector(of: webView), inspector.isVisible else { return }
        inspector.close()
    }

    // MARK: - SPI access

    fileprivate static func inspector(of webView: WKWebView) -> WKInspectorSPI? {
        guard isAvailable, webView.responds(to: inspectorGetter),
              let object = webView.perform(inspectorGetter)?.takeUnretainedValue() else { return nil }
        for name in requiredInspectorSelectors where !(object as AnyObject).responds(to: NSSelectorFromString(name)) {
            NSLog("Browser: WebKit inspector object lacks %@ -- falling back to Safari hand-off", name)
            return nil
        }
        return unsafeBitCast(object as AnyObject, to: WKInspectorSPI.self)
    }

    /// WebKit silently ignores show() unless the page's developerExtrasEnabled
    /// preference is on -- isInspectable only covers remote (Safari) inspection.
    /// It is enabled lazily, on the first open, because it also adds WebKit's
    /// own "Inspect Element" item to the page's default context menu.
    /// WKPreferences is shared by reference with the live page, so setting it
    /// here takes effect without recreating the web view.
    private static func enableDeveloperExtras(for webView: WKWebView) {
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: developerExtrasSetter) else { return }
        unsafeBitCast(preferences, to: WKPreferencesSPI.self)._setDeveloperExtrasEnabled(true)
    }

    /// There is no `isAttached` selector. An attached inspector's own web
    /// view is inserted as a sibling of the inspected web view (WebKit adds
    /// it to the inspected view's superview); a detached one lives in its
    /// own window. That placement is the tell.
    fileprivate static func isAttached(_ inspector: WKInspectorSPI, to webView: WKWebView) -> Bool {
        guard let frontend = inspector.inspectorWebView, let host = webView.superview else { return false }
        return frontend.isDescendant(of: host) && !frontend.isDescendant(of: webView)
    }

    private static func missingSelectors() -> [String] {
        var missing: [String] = []
        if class_getInstanceMethod(WKWebView.self, inspectorGetter) == nil { missing.append("-[WKWebView _inspector]") }
        if class_getInstanceMethod(WKPreferences.self, developerExtrasSetter) == nil {
            missing.append("-[WKPreferences _setDeveloperExtrasEnabled:]")
        }
        guard NSClassFromString("_WKInspector") != nil else { return missing + ["_WKInspector class"] }
        for name in requiredInspectorSelectors where !inspectorClassResponds(to: name) {
            missing.append("-[_WKInspector \(name)]")
        }
        return missing
    }

    private static func inspectorClassResponds(to name: String) -> Bool {
        guard let cls = NSClassFromString("_WKInspector") else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString(name)) != nil
    }
}

/// The subset of `_WKInspector` this file uses. Optional members are the
/// ones WebKitInspector checks per call rather than requiring up front.
@objc private protocol WKInspectorSPI {
    func show()
    func close()
    func attach()
    var isVisible: Bool { get }
    var inspectorWebView: WKWebView? { get }
    @objc optional func showConsole()
    @objc optional func toggleElementSelection()
    @objc optional func isElementSelectionActive() -> Bool
}

@objc private protocol WKPreferencesSPI {
    func _setDeveloperExtrasEnabled(_ enabled: Bool)
}

/// A hidden, zero-size subview of an inspected WKWebView that sees the web
/// view enter and leave windows, which is how the inspector follows tab
/// switches and tab closes without hooks in the tab code:
///
/// - An *attached* inspector sits inside the tab's host view next to the web
///   view, so it leaves and returns with the tab by itself -- nothing to do.
/// - A *detached* inspector is its own window and would otherwise float over
///   whatever tab is now showing, so it is closed when its web view leaves
///   the window and reopened when the web view comes back.
/// - A web view that has left its superview altogether belongs to a closed
///   tab; its inspector is closed so no frontend view or window outlives it.
private final class WebKitInspectorWatcher: NSView {
    var hasOpened = false
    private var reopenWhenBackInWindow = false

    static func install(on webView: WKWebView) -> WebKitInspectorWatcher {
        if let existing = webView.subviews.lazy.compactMap({ $0 as? WebKitInspectorWatcher }).first {
            return existing
        }
        let watcher = WebKitInspectorWatcher(frame: .zero)
        watcher.isHidden = true
        webView.addSubview(watcher)
        return watcher
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let webView = superview as? WKWebView,
              let inspector = WebKitInspector.inspector(of: webView) else { return }

        if window != nil {
            if reopenWhenBackInWindow {
                reopenWhenBackInWindow = false
                inspector.show()
            }
            return
        }

        if inspector.isVisible, !WebKitInspector.isAttached(inspector, to: webView) {
            inspector.close()
            reopenWhenBackInWindow = true
        }
        // During removeFromSuperview the web view's superview may not be
        // cleared yet when this runs; check once the removal has finished.
        DispatchQueue.main.async { [weak webView] in
            guard let webView, webView.superview == nil,
                  let inspector = WebKitInspector.inspector(of: webView) else { return }
            self.reopenWhenBackInWindow = false
            if inspector.isVisible { inspector.close() }
        }
    }
}
