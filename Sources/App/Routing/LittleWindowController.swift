import AppKit
import SecurityInterface

/// A small window for a link from another app: one page, under a thin header
/// with the site, the profile's dot and "Open in Browser" (⌘O). ⌘W closes
/// it, and so does Escape when the page itself does not have focus (see
/// handleKeyDown). Opened by RoutingCoordinator when LinkOpening resolves to
/// `.littleWindow`, and by `browser open --little`.
///
/// The page is an ordinary Tab, owned here rather than by a
/// BrowserWindowController. "Open in Browser" hands that same Tab -- engine
/// browser and all -- to the profile's frontmost normal window, so the page
/// moves without reloading and keeps its scroll position, form state and
/// back/forward list.
///
/// Deliberately outside WindowManager.windowControllers: that list is what
/// session.json, the CLI's `windows`/`tabs` and profile-scoped lookups walk,
/// and a little window is none of those things -- it is never restored, and
/// a routed link must never land in one as "the profile's frontmost window".
/// For the same reason no TabLifecycleEvent is posted while the tab lives
/// here: every observer takes, and several act on, the owning
/// BrowserWindowController. So until the page is opened in the browser
/// (BrowserWindowController.adoptTab posts `.opened` then):
/// - PageMessageDispatcher is not wired, so page messages go unanswered --
///   the Notification permission override, the tab-sleep page script and Web
///   Push subscriptions among them;
/// - SiteSettingsEnforcer does not apply a site's auto-mute;
/// - password and address autofill, the Reader button and the audio
///   indicator are absent.
final class LittleWindowController: NSWindowController, NSWindowDelegate, TabDelegate {
    private static var openControllers: [LittleWindowController] = []
    private static var keyMonitor: Any?

    private static let headerHeight: CGFloat = 28
    private static let defaultContentSize = NSSize(width: 860, height: 620)

    let profile: Profile
    let tab: Tab

    /// True once the tab has been handed to a browser window, so closing
    /// this window must not close the tab along with it.
    private var handedOff = false

    private let hostLabel = NSTextField(labelWithString: "")
    private let profileDot: ProfileDotView
    private let spinner = NSProgressIndicator()
    private let openInBrowserButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private let contentContainer = NSView()
    private let permissionPrompt = PermissionPromptController()
    private var pendingPermissionPromptId: UInt64?
    private var downloadsHoldingWindowOpen: Set<Int64> = []
    private let siteCard = SiteCardController()

    // MARK: - Opening

    @discardableResult
    static func open(url: String, profile: Profile) -> LittleWindowController {
        let controller = LittleWindowController(url: url, profile: profile)
        openControllers.append(controller)
        installKeyMonitorIfNeeded()
        controller.present()
        return controller
    }

    static var all: [LittleWindowController] { openControllers }

    /// A link that cold-launches the app is routed before the session is
    /// restored, so the restored windows land on top of its little window.
    /// AppDelegate calls this once restore is done.
    static func orderAllFront() {
        for controller in openControllers where controller.window?.isVisible == true {
            controller.orderFront()
        }
    }

    static func closeAll(forProfileId profileId: String? = nil) {
        for controller in openControllers where profileId == nil || controller.profile.id == profileId {
            controller.window?.close()
        }
    }

    private init(url: String, profile: Profile) {
        self.profile = profile
        self.profileDot = ProfileDotView(colorHex: profile.colorHex)
        tab = Tab(profileName: profile.name, profileId: profile.id, initialURL: url)
        // That focus grab exists for a tab opened with ⌘T; this page came
        // from a link, and must keep focus once it moves into a browser window.
        tab.needsInitialOmniboxFocus = false

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.tabbingMode = .disallowed
        window.title = url
        super.init(window: window)
        window.delegate = self
        tab.delegate = self
        setUpViews()
        refreshHeader()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }

        let header = NSVisualEffectView()
        header.material = .titlebar
        header.blendingMode = .withinWindow
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(separator)

        hostLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        profileDot.toolTip = profile.name
        profileDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            profileDot.widthAnchor.constraint(equalToConstant: 8),
            profileDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])

        let siteStack = NSStackView(views: [profileDot, hostLabel, spinner])
        siteStack.orientation = .horizontal
        siteStack.spacing = 6
        siteStack.alignment = .centerY
        siteStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(siteStack)

        openInBrowserButton.target = self
        openInBrowserButton.action = #selector(openInBrowser(_:))
        openInBrowserButton.bezelStyle = .rounded
        openInBrowserButton.controlSize = .small
        openInBrowserButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        openInBrowserButton.toolTip = "Open in Browser (⌘O)"
        openInBrowserButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(openInBrowserButton)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        // Room for the traffic lights, which float over the header's
        // leading edge because the title bar is transparent.
        let trafficLightInset: CGFloat = 78
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),

            siteStack.centerXAnchor.constraint(equalTo: header.centerXAnchor).withPriority(.defaultLow),
            siteStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            siteStack.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor, constant: trafficLightInset),
            siteStack.trailingAnchor.constraint(lessThanOrEqualTo: openInBrowserButton.leadingAnchor, constant: -8),

            openInBrowserButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            openInBrowserButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func present() {
        guard let window else { return }
        placeWindow(window)
        if CommandLineArgs.testNoActivate() {
            window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        }
        orderFront()

        contentView.layoutSubtreeIfNeeded()
        tab.hostView.frame = contentContainer.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        contentContainer.addSubview(tab.hostView)
        // The engine needs the host view in a window with real bounds.
        tab.createBrowserIfNeeded()
    }

    private func orderFront() {
        guard let window else { return }
        // Never order a window on screen while an omnibox has focus: its
        // system completion list asserts on the ordering walk and takes the
        // app down (see CLAUDE.md). A link that arrives while Brady is typing
        // in the address bar would otherwise do exactly that.
        for case let browserWindow as BrowserWindow in NSApp.windows {
            if let editor = browserWindow.firstResponder as? NSTextView, editor.isFieldEditor {
                browserWindow.makeFirstResponder(nil)
            }
        }
        if CommandLineArgs.testNoActivate() {
            window.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private var contentView: NSView { window?.contentView ?? contentContainer }

    /// Centered on the screen the pointer is on (where the link was just
    /// clicked), each further one offset so a second doesn't hide the first.
    private func placeWindow(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let size = NSSize(
            width: min(window.frame.width, visible.width),
            height: min(window.frame.height, visible.height)
        )
        let cascade = CGFloat(Self.openControllers.count - 1) * 24
        let origin = NSPoint(
            x: min(visible.midX - size.width / 2 + cascade, visible.maxX - size.width),
            y: max(visible.midY - size.height / 2 - cascade, visible.minY)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    // MARK: - Keys

    /// ⌘W closes and ⌘O opens in the browser -- taken before the page or the
    /// main menu sees them, since the page's own view is first responder
    /// almost all the time. Escape is taken only when the page does not have
    /// focus. Everything else is the page's.
    private static func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let controller = openControllers.first(where: { $0.window === event.window && $0.window?.isKeyWindow == true }) else {
                return event
            }
            return controller.handleKeyDown(event) ? nil : event
        }
    }

    private static func removeKeyMonitorIfUnused() {
        guard openControllers.isEmpty, let monitor = keyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53, flags.isEmpty {
            // A page uses Escape to leave video fullscreen or dismiss its own
            // dialog, and closing the window there would throw away the page
            // and anything typed into it. So Escape closes only when the
            // focus is outside the page, the window is not fullscreen and no
            // permission prompt is up.
            guard let window, !window.styleMask.contains(.fullScreen), !permissionPrompt.isShowing else { return false }
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: tab.hostView) { return false }
            window.performClose(nil)
            return true
        }
        if key == "w", flags == .command {
            window?.performClose(nil)
            return true
        }
        if key == "o", flags == .command {
            openInBrowser(nil)
            return true
        }
        return false
    }

    // MARK: - Actions

    /// Moves the page into the profile's frontmost normal window, after the
    /// active tab and never among the pinned ones, or a new window if the
    /// profile has none open. The engine browser moves with it, unloaded.
    @objc func openInBrowser(_ sender: Any?) {
        guard !handedOff else { return }
        handedOff = true
        siteCard.close()
        dismissPermissionPrompt()
        tab.hostView.removeFromSuperview()
        if let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            controller.adoptTab(tab, makeActive: true)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, adoptingPopup: tab, isPrivate: false)
        }
        window?.close()
    }

    /// File > Close Tab, whose ⌘W the key monitor normally takes first.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(nil)
    }

    @objc func reloadPage(_ sender: Any?) { tab.reload() }
    @objc func goBackAction(_ sender: Any?) { tab.goBack() }
    @objc func goForwardAction(_ sender: Any?) { tab.goForward() }
    @objc func zoomIn(_ sender: Any?) { tab.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { tab.zoomOut() }
    @objc func actualSize(_ sender: Any?) { tab.resetZoom() }

    @objc func copyCurrentURL(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tab.urlString, forType: .string)
    }

    // MARK: - Header

    private func refreshHeader() {
        let host = URL(string: tab.urlString)?.host ?? ""
        hostLabel.stringValue = Self.displayHost(host)
        hostLabel.toolTip = tab.urlString
        profileDot.colorHex = profile.colorHex
        if tab.isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        window?.title = tab.displayTitle.isEmpty ? host : tab.displayTitle
    }

    private static func displayHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        dismissPermissionPrompt()
        siteCard.close()
        if !handedOff {
            tab.hostView.removeFromSuperview()
            tab.close()
        }
        Self.openControllers.removeAll { $0 === self }
        Self.removeKeyMonitorIfUnused()
    }

    private func dismissPermissionPrompt() {
        guard pendingPermissionPromptId != nil else { return }
        pendingPermissionPromptId = nil
        permissionPrompt.dismiss(invokingDecision: true)
    }

    // MARK: - TabDelegate

    func tabDidChangeDisplayState(_ tab: Tab) {
        refreshHeader()
    }

    func tab(_ tab: Tab, didCommitNavigationTo url: String) {
        let history = ProfileDataStoreManager.shared.stores(for: profile).history
        // Until the new page reports its title, tab.title is still the
        // previous page's, which must not be stored under this URL.
        try? history.recordVisit(url: url, title: tab.hasFreshTitle ? tab.title : nil)
    }

    func tab(_ tab: Tab, didReceiveTitle title: String) {
        let history = ProfileDataStoreManager.shared.stores(for: profile).history
        try? history.updateTitle(url: tab.urlString, title: title)
    }

    func tab(_ tab: Tab, didChangeURLTo url: String) {
        refreshHeader()
    }

    func tabDidFinishLoading(_ tab: Tab) {
        refreshHeader()
    }

    /// A link that turns out to be a file leaves nothing to show: Tab has
    /// already put the page back on the start page. The window goes off
    /// screen at once, but closes -- taking the engine tab with it -- only
    /// once the download finishes, since neither engine promises a download
    /// outlives the browser that started it.
    func tab(_ tab: Tab, didBeginDownload info: TabDownloadStart) {
        DownloadCoordinator.shared.beginDownload(profile: profile, info: info)
        guard !tab.hasCommittedPage, !handedOff else { return }
        downloadsHoldingWindowOpen.insert(info.downloadId)
        dismissPermissionPrompt()
        window?.orderOut(nil)
    }

    func tab(_ tab: Tab, didUpdateDownload info: TabDownloadUpdate) {
        DownloadCoordinator.shared.updateDownload(profile: profile, info: info)
        guard info.isComplete || info.isCancelled || info.isInterrupted,
              downloadsHoldingWindowOpen.remove(info.downloadId) != nil,
              downloadsHoldingWindowOpen.isEmpty, !handedOff else { return }
        window?.close()
    }

    func tab(_ tab: Tab, didRequestPermission kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        let store = PermissionStoreManager.shared.store(for: profile)
        if let remembered = store.decision(for: requestingOrigin, kinds: kinds) {
            decision(remembered)
            return
        }
        pendingPermissionPromptId = promptId
        permissionPrompt.show(kinds: kinds, origin: requestingOrigin, anchorView: hostLabel) { [weak self] allow in
            self?.pendingPermissionPromptId = nil
            store.setDecision(allow, for: requestingOrigin, kinds: kinds)
            decision(allow)
        }
    }

    func tab(_ tab: Tab, didDismissPermissionRequestWithId promptId: UInt64) {
        guard pendingPermissionPromptId == promptId else { return }
        pendingPermissionPromptId = nil
        permissionPrompt.dismiss(invokingDecision: false)
    }

    /// A link this page opens in a new tab goes to the browser, where tabs
    /// are -- a little window only ever shows the one page.
    func tab(_ tab: Tab, didRequestNewTabForURL url: String, foreground: Bool) {
        guard let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
            return
        }
        controller.openTabForLinkClick(url: url, afterIndex: controller.activeTabIndex ?? controller.tabs.count, foreground: foreground)
        if foreground { controller.window?.makeKeyAndOrderFront(nil) }
    }

    func tab(_ tab: Tab, didRequestNewWindowForURL url: String) {
        WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
    }

    /// Must be adopted synchronously (see TabDelegate), and a browser window
    /// is the only place that can hold a second tab.
    func tab(_ tab: Tab, didOpenPopup popup: Tab, inNewWindow: Bool, foreground: Bool) {
        if !inNewWindow, let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            controller.adoptTab(popup, makeActive: foreground)
            if foreground { controller.window?.makeKeyAndOrderFront(nil) }
            return
        }
        WindowManager.shared.openNewWindow(profile: profile, adoptingPopup: popup, isPrivate: false)
    }

    func tabDidRequestClose(_ tab: Tab) {
        guard tab === self.tab else { return }
        window?.close()
    }

    /// The page's "Site Information…" item. The card hangs from the header's
    /// host label. Site settings are left out: that sheet belongs to a
    /// browser window, and "Open in Browser" is one click away.
    func tabDidRequestSiteInformation(_ tab: Tab) {
        guard tab === self.tab, !tab.urlString.isEmpty, window?.isVisible == true else { return }
        if siteCard.isShown {
            siteCard.close()
            return
        }
        siteCard.show(for: tab, relativeTo: hostLabel, actions: SiteCardActions(
            copyAddress: { [weak tab] in
                guard let tab else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.urlString, forType: .string)
            },
            print: { [weak tab] in tab?.print() },
            showSiteSettings: nil,
            showCertificate: { [weak self] trust in
                guard let window = self?.window else { return }
                SFCertificatePanel.shared().beginSheet(
                    for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true)
            }
        ))
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
