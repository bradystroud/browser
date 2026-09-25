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
/// WKWebView `_inspector`, `_setInspectorAttachmentView:`,
/// `_inspectorAttachmentView`; on WKPreferences `_setDeveloperExtrasEnabled:`;
/// on `_WKInspector` `show`, `close`, `hide`, `attach`, `detach`,
/// `isVisible`, `isConnected`, `isFront`, `showConsole`, `showResources`,
/// `showMainResourceForFrame:`, `toggleElementSelection`,
/// `isElementSelectionActive`, `togglePageProfiling`, `inspectorWebView`,
/// `setDelegate:`. There is no `isAttached`, no dock-side setter and no
/// "inspect element at point" -- see WebKitInspectorSession for how each is
/// covered.
enum WebKitInspector {
    private static let inspectorGetter = NSSelectorFromString("_inspector")
    private static let developerExtrasSetter = NSSelectorFromString("_setDeveloperExtrasEnabled:")
    static let attachmentViewSetter = NSSelectorFromString("_setInspectorAttachmentView:")

    /// Selectors the core show/close path cannot work without. Console and
    /// element selection are checked separately, so their absence only
    /// narrows what opens rather than disabling the inspector outright.
    private static let requiredInspectorSelectors = ["show", "close", "attach", "detach", "isVisible", "inspectorWebView"]

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

    /// Docking into a view the app owns additionally needs the attachment-view
    /// setter; without it the inspector can still open, just in its own window.
    static let canDockIntoContainer: Bool = {
        isAvailable && class_getInstanceMethod(WKWebView.self, attachmentViewSetter) != nil
    }()

    static var canShowConsole: Bool { isAvailable && inspectorClassResponds(to: "showConsole") }
    static var canSelectElement: Bool {
        isAvailable && inspectorClassResponds(to: "toggleElementSelection")
            && inspectorClassResponds(to: "isElementSelectionActive")
    }

    // MARK: - SPI access

    static func inspector(of webView: WKWebView) -> WKInspectorSPI? {
        guard isAvailable, webView.responds(to: inspectorGetter),
              let object = webView.perform(inspectorGetter)?.takeUnretainedValue() else { return nil }
        for name in requiredInspectorSelectors where !(object as AnyObject).responds(to: NSSelectorFromString(name)) {
            NSLog("Browser: WebKit inspector object lacks %@ -- falling back to Safari hand-off", name)
            return nil
        }
        return unsafeBitCast(object as AnyObject, to: WKInspectorSPI.self)
    }

    /// Whether `inspector` has a frontend at all, visible yet or not.
    static func isOpen(_ inspector: WKInspectorSPI) -> Bool {
        (inspector as AnyObject).responds(to: NSSelectorFromString("isConnected"))
            ? inspector.isConnected?() == true
            : inspector.isVisible
    }

    /// WebKit silently ignores show() unless the page's developerExtrasEnabled
    /// preference is on -- isInspectable only covers remote (Safari) inspection.
    /// Turning it on also adds WebKit's own "Inspect Element" to the page's
    /// default context menu, which is wanted: it is the only right-click route
    /// to the inspector on this engine. WKPreferences is shared by reference
    /// with the live page, so this works before or after the first load.
    static func enableDeveloperExtras(for webView: WKWebView) {
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: developerExtrasSetter) else { return }
        unsafeBitCast(preferences, to: WKPreferencesSPI.self)._setDeveloperExtrasEnabled(true)
    }

    static func setAttachmentView(_ view: NSView?, for webView: WKWebView) {
        guard canDockIntoContainer else { return }
        unsafeBitCast(webView, to: WKWebViewInspectorSPI.self)._setInspectorAttachmentView(view)
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

    static func inspectorClassResponds(to name: String) -> Bool {
        guard let cls = NSClassFromString("_WKInspector") else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString(name)) != nil
    }
}

/// The subset of `_WKInspector` this file uses. Optional members are the
/// ones checked per call rather than required up front.
@objc protocol WKInspectorSPI {
    func show()
    func close()
    func attach()
    func detach()
    var isVisible: Bool { get }
    var inspectorWebView: WKWebView? { get }
    @objc optional func isConnected() -> Bool
    @objc optional func showConsole()
    @objc optional func toggleElementSelection()
    @objc optional func isElementSelectionActive() -> Bool
    @objc optional func setDelegate(_ delegate: AnyObject?)
}

@objc private protocol WKPreferencesSPI {
    func _setDeveloperExtrasEnabled(_ enabled: Bool)
}

@objc private protocol WKWebViewInspectorSPI {
    func _setInspectorAttachmentView(_ view: NSView?)
}

/// One tab's inspector state: where the app wants it (a dock container, or
/// WebKit's own window), what to do once its frontend has loaded, and the
/// bookkeeping that turns WebKit's view juggling back into open/close/dock
/// side events for the tab's delegate. Held by its web view (see
/// `session(for:)`), so WebKitTab needs no stored property for it.
///
/// How docking into an app-owned container works: WebKit lays an attached
/// inspector out next to the web view's "attachment view" -- it adds its own
/// frontend web view to that view's superview and sizes both to share the
/// superview's bounds. `_setInspectorAttachmentView:` lets that view be any
/// view, so it is set to a transparent, frame-locked stand-in placed inside a
/// host view that fills the app's container. WebKit then inserts the frontend
/// into the container, never touches the real web view, and its size
/// arithmetic only ever lands on the stand-in (which ignores it) and on the
/// frontend (which the host snaps back to fill the container). The app's own
/// split view decides the real sizes.
final class WebKitInspectorSession: NSObject {
    private weak var webView: WKWebView?

    /// Forwarded to the tab's delegate by WebKitTab.
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onDockSideRequest: ((DevToolsDockSide) -> Void)?
    var onOpenURLExternally: ((URL) -> Void)?

    private var host: WebKitInspectorDockHost?

    /// Where the app wants the frontend. `.window` is WebKit's own window.
    private var expectedSide: DevToolsDockSide = .bottom
    private var wantsDocked: Bool { expectedSide != .window }
    /// The side WebKit itself last docked the frontend on, which drives its
    /// dock buttons' state; nil while it is not in the host.
    private var hostSide: DevToolsDockSide?
    /// Set while a dock move this session asked for is still on its way, so
    /// WebKit's intermediate placements are not mistaken for the user's.
    private var awaitingSide = false

    private var isOpening = false
    private var isClosing = false
    private var frontendLoaded = false
    private var pendingFrontendScripts: [String] = []

    private static var associationKey: UInt8 = 0

    static func session(for webView: WKWebView) -> WebKitInspectorSession {
        if let existing = objc_getAssociatedObject(webView, &associationKey) as? WebKitInspectorSession {
            return existing
        }
        let session = WebKitInspectorSession(webView: webView)
        objc_setAssociatedObject(webView, &associationKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }

    private init(webView: WKWebView) {
        self.webView = webView
        super.init()
        WebKitInspector.enableDeveloperExtras(for: webView)
        WebKitInspectorWatcher.install(on: webView)
    }

    private var inspector: WKInspectorSPI? { webView.flatMap(WebKitInspector.inspector(of:)) }

    var isOpen: Bool { inspector.map(WebKitInspector.isOpen) ?? false }

    // MARK: - Commands

    /// Returns false when the SPI is unavailable, so the caller can fall back.
    func show(panel: DevToolsPanel, dockSide: DevToolsDockSide, in container: NSView?) -> Bool {
        guard let inspector else { return false }
        let side: DevToolsDockSide = container != nil && WebKitInspector.canDockIntoContainer ? dockSide : .window
        if side != expectedSide { awaitingSide = side != .window }
        expectedSide = side
        if let container, side != .window { place(in: container) }

        switch panel {
        case .default: break
        case .console:
            // WebKit's frontend dispatcher queues this until the page loads.
            if WebKitInspector.canShowConsole { inspector.showConsole?() }
        case .elements:
            runInFrontend("WI.showElementsTab();")
        }

        // Inside the open callback WebKit is mid-open already: calling show()
        // again would race it, and the callback applies the placement itself.
        guard !isOpening else { return true }
        if WebKitInspector.isOpen(inspector) {
            applyPlacement()
            inspector.show()
        } else {
            inspector.setDelegate?(self)
            inspector.show()
        }
        return true
    }

    func close() {
        guard let inspector, WebKitInspector.isOpen(inspector) else { return }
        inspector.close()
    }

    func startElementPicker() {
        guard let inspector, WebKitInspector.canSelectElement else {
            runInFrontend("WI.showElementsTab();")
            return
        }
        if inspector.isElementSelectionActive?() != true { inspector.toggleElementSelection?() }
    }

    /// There is no inspect-at-point SPI. The frontend's own runtime can
    /// evaluate in the page with the Command Line API, though, and
    /// `inspect(node)` there is exactly the console's `inspect()`: it reveals
    /// the node in the Elements tab. The node is found with elementFromPoint,
    /// descending into same-origin frames (a cross-origin frame stops at its
    /// <iframe> element).
    func inspectElement(at point: NSPoint) {
        guard let webView else { return }
        let scale = max(webView.pageZoom * webView.magnification, 0.01)
        let viewY = webView.isFlipped ? point.y : webView.bounds.height - point.y
        let finder = """
        (function (x, y) {
          var e = document.elementFromPoint(x, y);
          while (e && (e.tagName === "IFRAME" || e.tagName === "FRAME")) {
            try {
              var d = e.contentDocument; if (!d) break;
              var r = e.getBoundingClientRect();
              x -= r.left + e.clientLeft; y -= r.top + e.clientTop;
              var inner = d.elementFromPoint(x, y); if (!inner) break;
              e = inner;
            } catch (_) { break; }
          }
          return e;
        })(\(Double(point.x / scale)), \(Double(viewY / scale)))
        """
        guard let data = try? JSONSerialization.data(withJSONObject: ["inspect(\(finder))"]),
              let array = String(data: data, encoding: .utf8) else { return }
        // "Frontend loaded" can arrive before the frontend knows the page's
        // execution context, and evaluating without one silently does
        // nothing -- so wait (up to 5s) for the context first.
        runInFrontend("""
        (function attempt(triesLeft) {
          if (!WI.runtimeManager.activeExecutionContext) {
            if (triesLeft > 0) setTimeout(function () { attempt(triesLeft - 1); }, 100);
            return;
          }
          WI.runtimeManager.evaluateInInspectedWindow(\(array)[0], {
            objectGroup: "brw-inspect-at-point", includeCommandLineAPI: true,
            doNotPauseOnExceptionsAndMuteConsole: true
          }, function () {});
        })(50);
        """)
    }

    // MARK: - Placement

    private func place(in container: NSView) {
        guard let webView else { return }
        if host?.superview !== container {
            let host = self.host ?? WebKitInspectorDockHost(session: self)
            host.removeFromSuperview()
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            self.host = host
        }
        if let host {
            WebKitInspector.setAttachmentView(host.attachmentStandIn, for: webView)
        }
    }

    /// Moves an already-open frontend to where the app now wants it.
    private func applyPlacement() {
        guard let inspector else { return }
        if wantsDocked {
            if hostSide == nil {
                awaitingSide = true
                inspector.attach()
            }
            requestWebKitSideIfNeeded()
        } else if hostSide != nil {
            inspector.detach()
        }
    }

    /// WebKit only docks on the side its frontend asks for, and only the
    /// frontend page can ask (InspectorFrontendHost.requestSetDockSide, the
    /// call its own dock buttons make). The layout does not depend on it --
    /// the host fills the container whatever WebKit believes -- but the
    /// frontend's own dock buttons and resizer do.
    private func requestWebKitSideIfNeeded() {
        guard wantsDocked, hostSide != expectedSide else { return }
        awaitingSide = true
        runInFrontend("InspectorFrontendHost.requestSetDockSide(\"\(expectedSide.rawValue)\");")
    }

    private func runInFrontend(_ script: String) {
        let guarded = "try { if (window.WI && window.InspectorFrontendHost) { \(script) } } catch (e) { console.error(e); }"
        if frontendLoaded, let frontend = inspector?.inspectorWebView {
            frontend.evaluateJavaScript(guarded, completionHandler: nil)
        } else {
            pendingFrontendScripts.append(guarded)
        }
    }

    // MARK: - WebKit callbacks (via WebKitTab's UI delegate and _WKInspectorDelegate)

    /// `_webView:didAttachLocalInspector:` -- WebKit's frontend page exists
    /// but has neither loaded nor been placed anywhere yet, whoever opened
    /// it. The tab's delegate hears first, so an open the app did not ask
    /// for (WebKit's own Inspect Element) can be claimed for its container.
    func inspectorDidConnect() {
        isClosing = false
        frontendLoaded = false
        hostSide = nil
        inspector?.setDelegate?(self)
        isOpening = true
        onOpen?()
        isOpening = false
        // Deciding attached-or-not here, before the frontend loads, is what
        // keeps a separate window from flashing up before a docked open.
        guard let inspector else { return }
        if wantsDocked {
            awaitingSide = true
            inspector.attach()
        } else {
            inspector.detach()
        }
    }

    /// `_webView:willCloseLocalInspector:`.
    func inspectorWillClose() {
        isClosing = true
        frontendLoaded = false
        awaitingSide = false
        pendingFrontendScripts.removeAll()
        onClose?()
    }

    @objc(inspectorFrontendLoaded:)
    func inspectorFrontendLoaded(_ inspector: AnyObject) {
        frontendLoaded = true
        requestWebKitSideIfNeeded()
        let scripts = pendingFrontendScripts
        pendingFrontendScripts.removeAll()
        for script in scripts { self.inspector?.inspectorWebView?.evaluateJavaScript(script, completionHandler: nil) }
    }

    /// Links the frontend opens "externally" (a resource's Open in New Tab).
    @objc(inspector:openURLExternally:)
    func inspector(_ inspector: AnyObject, openURLExternally url: NSURL) {
        onOpenURLExternally?(url as URL)
    }

    // MARK: - Host events

    /// WebKit put its frontend into the host on `side`.
    fileprivate func frontendDocked(on side: DevToolsDockSide) {
        hostSide = side
        guard !isClosing else { return }
        if awaitingSide {
            if side == expectedSide { awaitingSide = false } else if frontendLoaded { requestWebKitSideIfNeeded() }
            return
        }
        guard side != expectedSide else { return }
        // The frontend's own dock buttons moved it.
        expectedSide = side
        onDockSideRequest?(side)
    }

    /// WebKit took its frontend out of the host: a re-dock (it comes
    /// straight back), a close, or the frontend's own Detach button.
    fileprivate func frontendLeftHost() {
        hostSide = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosing, self.hostSide == nil, self.wantsDocked,
                  let inspector = self.inspector, WebKitInspector.isOpen(inspector) else { return }
            self.expectedSide = .window
            self.awaitingSide = false
            self.onDockSideRequest?(.window)
        }
    }
}

/// Fills the app's dock container and holds WebKit's attached frontend. See
/// WebKitInspectorSession for why WebKit's own layout is overridden here.
private final class WebKitInspectorDockHost: NSView {
    let attachmentStandIn = WebKitInspectorAttachmentStandIn()
    private weak var session: WebKitInspectorSession?
    private weak var frontend: NSView?
    private var frameObserver: NSObjectProtocol?

    init(session: WebKitInspectorSession) {
        self.session = session
        super.init(frame: .zero)
        addSubview(attachmentStandIn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== attachmentStandIn else { return }
        // platformAttach sets the frontend's autoresizing mask for its side
        // just before adding it -- the only place the side is visible.
        let mask = subview.autoresizingMask
        let side: DevToolsDockSide
        if mask.contains(.minXMargin) { side = .right } else if mask.contains(.maxXMargin) { side = .left } else { side = .bottom }
        frontend = subview
        subview.autoresizingMask = [.width, .height]
        fill(subview)
        frameObserver.map(NotificationCenter.default.removeObserver)
        subview.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: subview, queue: nil
        ) { [weak self, weak subview] _ in
            guard let self, let subview else { return }
            self.fill(subview)
        }
        session?.frontendDocked(on: side)
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === frontend else { return }
        frameObserver.map(NotificationCenter.default.removeObserver)
        frameObserver = nil
        frontend = nil
        session?.frontendLeftHost()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if let frontend { fill(frontend) }
    }

    private func fill(_ view: NSView) {
        if view.frame != bounds { view.frame = bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === attachmentStandIn ? nil : hit
    }

    deinit {
        frameObserver.map(NotificationCenter.default.removeObserver)
    }
}

/// What WebKit treats as the inspected view when docking. It must be visible
/// and big enough for WebKit's "can attach" check (at least 500 wide, 333
/// tall), and it ignores every frame WebKit assigns it: the app's split view
/// sizes the real page, not WebKit.
private final class WebKitInspectorAttachmentStandIn: NSView {
    private var isFrameLocked = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        autoresizingMask = []
        isFrameLocked = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var frame: NSRect {
        get { super.frame }
        set { if !isFrameLocked { super.frame = newValue } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if !isFrameLocked { super.setFrameSize(newSize) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if !isFrameLocked { super.setFrameOrigin(newOrigin) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// A hidden, zero-size subview of an inspected WKWebView that notices when
/// its web view has left its superview for good -- the tab was closed -- and
/// closes the inspector, so no docked frontend or separate window outlives
/// it. Tab switches only move the tab's whole view tree out of the window,
/// so an open inspector, docked or in its own window, stays open across
/// them, as Chrome's does.
private final class WebKitInspectorWatcher: NSView {
    static func install(on webView: WKWebView) {
        guard !webView.subviews.contains(where: { $0 is WebKitInspectorWatcher }) else { return }
        let watcher = WebKitInspectorWatcher(frame: .zero)
        watcher.isHidden = true
        webView.addSubview(watcher)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        // During removeFromSuperview the web view's superview may not be
        // cleared yet when this runs; check once the removal has finished.
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.superview as? WKWebView, webView.superview == nil,
                  let inspector = WebKitInspector.inspector(of: webView),
                  WebKitInspector.isOpen(inspector) else { return }
            inspector.close()
        }
    }
}
