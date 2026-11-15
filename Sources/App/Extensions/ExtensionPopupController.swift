import AppKit

/// An extension's action popup for an engine that cannot show one by itself
/// (ExtensionHost.extensionPresentPopup): the popup page in an engine tab the
/// app owns, in a small panel hung below the extension's toolbar button as a
/// child of its window, and sized by the page
/// (`EngineCapabilities.pageAutoResize`). A panel, not an NSPopover: CEF's
/// page did not draw reliably inside a popover's window.
///
/// The engine tab is not a browser tab. It is never in a tab strip or the
/// session, never reported to an extension system, and never in an agent's
/// window. One popup at a time; it closes when the page calls
/// `window.close()`, on Escape, when the user clicks elsewhere or switches
/// to another app, and with its window, so
/// no engine tab outlives the window (the engine waits for every one of its
/// tabs to close before the app can quit).
///
/// The panel is a window, so it is never ordered on screen while a text
/// field in the window is being edited (see CLAUDE.md on the omnibox): a
/// press of the button ends that editing first, and an extension's own
/// request is refused instead.
final class ExtensionPopupController: NSObject, EngineTabDelegate {
    /// Chrome's bounds for an action popup.
    static let minimumSize = NSSize(width: 25, height: 25)
    static let maximumSize = NSSize(width: 800, height: 600)

    private static var current: ExtensionPopupController?
    private static var closedByClick: (id: String, at: Date)?

    let extensionId: String
    let profileId: String
    private let panel: NSPanel
    private weak var anchor: NSView?
    private var eventMonitor: Any?
    private let hostView: NSView
    private var engineTab: EngineTab?
    private weak var controller: BrowserWindowController?
    private var observers: [NSObjectProtocol] = []
    private var isClosing = false

    /// Shows `request`'s page, replacing any popup already open. False when
    /// nothing is shown: the engine cannot size a page, the window is not a
    /// key window that runs extensions, or a text field in it is being
    /// edited and the extension asked by itself.
    static func present(_ request: EngineExtensionPopupRequest) -> Bool {
        let refuse = { (why: String) -> Bool in
            NSLog("Browser: not showing the popup of extension %@: %@", request.extensionId, why)
            return false
        }
        guard Engines.capabilities(for: request.engine).pageAutoResize else { return refuse("its engine cannot size a popup page") }
        // The extension asking by itself means the profile's focused window,
        // as `action.openPopup()` with no window does in Chrome.
        let candidates = request.requestedByExtension
            ? ExtensionsCoordinator.shared.extensionWindows(profileId: request.profileId)
            : [request.window].compactMap { $0 }
        let usable = candidates.filter { isUsable($0, profileId: request.profileId) }
        guard !usable.isEmpty else { return refuse("no window of the profile that runs its extensions") }
        guard let window = usable.first(where: { $0.extensionNSWindow?.isKeyWindow == true })
                ?? (standsInForKeyWindow() ? usable.first : nil),
              let controller = (window as? ExtensionWindowHandle)?.controller, let nsWindow = controller.window
        else { return refuse("its window is not the key window") }
        for editing in [nsWindow, NSApp.keyWindow].compactMap({ $0 }) where ExtensionsCoordinator.isEditingText(in: editing) {
            guard !request.requestedByExtension else { return refuse("a text field is being edited") }
            guard ExtensionsCoordinator.resignFieldEditor(in: editing) else { return refuse("a text field would not end editing") }
        }
        guard let profile = ProfileManager.shared.profile(id: request.profileId) else { return refuse("no such profile") }

        // The click on the button that closed the popup (the click landed
        // outside it) must not open it again: a second press closes it.
        if !request.requestedByExtension, let closed = closedByClick, closed.id == request.extensionId,
           Date().timeIntervalSince(closed.at) < 0.5 {
            closedByClick = nil
            return true
        }
        if let open = current {
            open.close()
            // A second press of the same button closes the popup, as in Chrome.
            if !request.requestedByExtension, open.extensionId == request.extensionId,
               open.profileId == request.profileId, open.url == request.url { return true }
        }

        let popup = ExtensionPopupController(request: request, controller: controller)
        if let anchor = window.extensionPopupAnchor(forExtension: request.extensionId), anchor.window === nsWindow,
           !anchor.isHiddenOrHasHiddenAncestor {
            popup.anchor = anchor
        }
        popup.show(in: nsWindow, takeKeyboard: !request.requestedByExtension)
        guard popup.panel.isVisible else {
            popup.close()
            return refuse("the panel did not open")
        }
        current = popup
        popup.start(profileName: profile.name, engine: request.engine)
        NSLog("Browser: showing the popup of extension %@ (%@)", request.extensionId,
              request.requestedByExtension ? "asked for by the extension" : "button pressed")
        return true
    }

    /// Closes whatever popup is open.
    static func closeCurrent() {
        current?.close()
    }

    /// A browser window of the profile that runs its extensions: never a
    /// private window, and never an agent's, even where a test instance
    /// lets agent pages run extensions.
    private static func isUsable(_ window: ExtensionHostWindow, profileId: String) -> Bool {
        guard let controller = (window as? ExtensionWindowHandle)?.controller, let nsWindow = controller.window else { return false }
        return nsWindow.isVisible && controller.runsExtensions && !controller.isPrivate && controller.agentPresentation == nil
            && controller.profile.id == profileId
            && WindowManager.shared.windowControllers.contains { $0 === controller }
    }

    /// `--test-popup-front-window`: under `--test-no-activate` the app is
    /// never active, so no window is ever key; with this flag the profile's
    /// front usable window stands in for it, so the popup can be tested
    /// without anyone clicking. Honored only with a scratch `--profiles-root`
    /// that is not the real data, nor inside or around it (the same rule as
    /// `--allow-agent-extensions`), so a normal install can never use it.
    private static func standsInForKeyWindow() -> Bool {
        CommandLine.arguments.contains("--test-popup-front-window") && CommandLineArgs.testNoActivate()
            && CommandLineArgs.allowsAgentExtensionsRoot
    }

    private let url: URL

    private init(request: EngineExtensionPopupRequest, controller: BrowserWindowController) {
        extensionId = request.extensionId
        profileId = request.profileId
        url = request.url
        self.controller = controller
        hostView = NSView(frame: NSRect(origin: .zero, size: Self.minimumSize))
        panel = ExtensionPopupPanel(contentRect: NSRect(origin: .zero, size: Self.minimumSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        hostView.autoresizingMask = [.width, .height]
        // As a tab's page view is: the engine composites the page into it.
        hostView.wantsLayer = true
        panel.contentView = hostView
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        if let window = controller.window {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.close() })
        }
    }

    /// Places the panel below the anchor (or the window's top trailing
    /// corner), inside the screen, as a child of `window` so it moves with
    /// it, and starts closing it on a click elsewhere, Escape, or the app
    /// going to the background.
    private func show(in window: NSWindow, takeKeyboard: Bool) {
        window.addChildWindow(panel, ordered: .above)
        place(size: Self.minimumSize)
        // Typing goes to the page only once the panel is key. A press of the
        // button makes it key at once. A popup the extension opened by
        // itself does not: the user may be typing into the page under it
        // (a password, say), and those keys must not reach the extension.
        // It becomes key on the user's first click in it. Never while the
        // app is in the background, which would not activate it anyway.
        if takeKeyboard, NSApp.isActive { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.window === self.panel, event.keyCode == 53 { self.close(); return nil }
            } else if event.window !== self.panel {
                Self.closedByClick = (self.extensionId, Date())
                self.close()
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.close() })
        // A popup no one can see must not stay open: its page holds the
        // extension's port, and an extension waiting on that port only
        // learns the popup is gone when it closes.
        let center = NotificationCenter.default
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.willEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.close()
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
            [weak self] _ in
            if !window.occlusionState.contains(.visible) { self?.close() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
            [weak self] _ in self?.followAnchor()
        })
        observers.append(center.addObserver(forName: .browserExtensionsDidChange, object: profileId, queue: .main) {
            [weak self] _ in self?.followAnchor()
        })
        hadAnchor = anchor != nil
    }

    private var hadAnchor = false

    /// Re-places the panel under its button, or closes it when the button
    /// is gone (unpinned, hidden, its layout changed) or the extension no
    /// longer runs in the profile's list.
    private func followAnchor() {
        guard engineTab != nil || panel.isVisible else { return }
        if hadAnchor {
            guard let anchor, anchor.window === controller?.window, !anchor.isHiddenOrHasHiddenAncestor else {
                NSLog("Browser: closing the popup of extension %@: its button is gone", extensionId)
                return close()
            }
        }
        if let manager = ExtensionsCoordinator.shared.manager,
           !manager.extensions(profileId: profileId).contains(where: { $0.id == extensionId && $0.isEnabled }) {
            NSLog("Browser: closing the popup of extension %@: it is no longer on", extensionId)
            return close()
        }
        place(size: panel.frame.size)
    }

    /// Top edge just below the anchor, trailing edge at the anchor's
    /// trailing edge, kept on the window's screen.
    private func place(size: NSSize) {
        guard let window = controller?.window else { return }
        let below: NSRect
        if let anchor, anchor.window === window {
            below = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        } else {
            let frame = window.frame
            below = NSRect(x: frame.maxX - 48, y: frame.maxY - 80, width: 40, height: 40)
        }
        var origin = NSPoint(x: below.maxX - size.width, y: below.minY - 4 - size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = max(origin.y, visible.minY)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// After the panel is on screen, so the engine's view is created
    /// inside a window.
    private func start(profileName: String, engine: EngineChoice) {
        let tab = Engines.createTab(engine: engine, profileName: profileName, profileId: profileId, hostView: hostView,
                                    initialURL: url.absoluteString, runsExtensions: true)
        tab.delegate = self
        tab.setAutoResize(enabled: true, minSize: Self.minimumSize, maxSize: Self.maximumSize)
        engineTab = tab
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        finish()
    }

    private func finish() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        defer {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if let tab = engineTab {
            engineTab = nil
            tab.delegate = nil
            tab.close()
            NSLog("Browser: closed the popup of extension %@", extensionId)
        }
        if Self.current === self { Self.current = nil }
    }

    static func clamped(_ size: NSSize) -> NSSize {
        NSSize(width: min(max(size.width, minimumSize.width), maximumSize.width),
               height: min(max(size.height, minimumSize.height), maximumSize.height))
    }

    // MARK: - EngineTabDelegate

    func engineTabDidAutoResize(to size: NSSize) {
        guard engineTab != nil, panel.isVisible else { return }
        let fitted = Self.clamped(size)
        guard fitted != panel.frame.size else { return }
        place(size: fitted)
        NSLog("Browser: popup of extension %@ sized to %.0fx%.0f (page asked for %.0fx%.0f)",
              extensionId, fitted.width, fitted.height, size.width, size.height)
    }

    func engineTabDidRequestClose() {
        NSLog("Browser: the popup page of extension %@ closed itself", extensionId)
        close()
    }

    /// A link the popup opens goes to a tab of its window, chosen by the
    /// engine rules, as in Chrome.
    func engineTabDidRequestNewTab(url: String, disposition: EngineWindowOpenDisposition) {
        guard let controller, controller.runsExtensions else { return }
        let foreground = disposition != .backgroundTab
        controller.addTab(url: url, makeActive: foreground)
        // Outside the engine's callback, which this request arrives in.
        if foreground { DispatchQueue.main.async { [weak self] in self?.close() } }
    }

    /// Only an engine that makes its own popup tabs sends this, and the
    /// popup's engine does not; one not adopted is closed.
    func engineTabDidCreatePopup(_ popup: EnginePopupTab, disposition: EngineWindowOpenDisposition) {
        popup.close()
    }

    func engineTabDidRequestPermission(_ kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        decision(false)
    }

    /// The popup carries none of the app's page scripts, so no message is
    /// one the app answers.
    func engineTabDidReceivePageMessage(_ request: String, requestId: Int64, source: PageMessageSource) {
        engineTab?.respondToPageMessage(requestId: requestId, success: false, response: "")
    }

    func engineTabDidChangeTitle(_ title: String) {}
    func engineTabDidChangeURL(_ url: String) {}
    func engineTabDidChangeFaviconURL(_ faviconURL: String?) {}
    func engineTabDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func engineTabWillStartMainFrameNavigation(_ url: String) {}
    func engineTabDidUpdateLoadingProgress(_ progress: Double) {}
    func engineTabDidCommitNavigation(_ url: String) {}
    func engineTabDidBeginDownload(id: Int64, url: String, suggestedName: String, destinationPath: String) {}
    func engineTabDidUpdateDownload(id: Int64, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCancelled: Bool, isInterrupted: Bool) {}
    func engineTabDidDismissPermissionRequest(_ promptId: UInt64) {}
    func engineTabDidUpdateFindResult(matchCount: Int, activeMatchOrdinal: Int, isFinalUpdate: Bool) {}
    func engineTabDidStartMainFrameLoad() {}
    func engineTabDidRequestVisualLookUp(imageURL: String, pageURL: String) {}
    func engineTabDidRequestViewSource(pageURL: String) {}
    func engineTabDidRequestSiteInformation() {}
    func engineTabDidChangeSecurityState() {}
    func engineTabDidRequestPeekLink(url: String) {}
    func engineTabDidRequestCopyImage(imageURL: String, pageURL: String) {}
    func engineTabDidRequestCopyImageLink(imageURL: String) {}
    func engineTabDidRequestDownloadImage(imageURL: String) {}
    func engineTabDidBlockRequest(trackerDomain: String, pageHost: String) {}
    func engineTabDevToolsDidOpen() {}
    func engineTabDevToolsDidClose() {}
    func engineTabDevToolsDidRequestDockSide(_ side: DevToolsDockSide) {}
    func engineTabDidRequestInspectElement(at point: NSPoint) {}
}

extension ExtensionsCoordinator {
    func extensionPresentPopup(_ request: EngineExtensionPopupRequest) -> Bool {
        ExtensionPopupController.present(request)
    }
}

/// Borderless, yet able to take the keyboard for the page it shows.
private final class ExtensionPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
