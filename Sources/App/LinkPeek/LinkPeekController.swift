import AppKit

/// A peek at a link: its page opens in a panel floating over the current
/// one, which stays loaded underneath, and takes keyboard focus. ⌘W, a click beside the panel, its close button, or Escape when the
/// page is not using it put the peek away; "Open as Tab"
/// keeps it as a tab next to the current one.
///
/// The peeked page is an ordinary Tab (same profile and privacy mode as the
/// window) that is simply not in the tab strip yet, so keeping it moves that
/// same Tab -- and the engine view already showing its page -- into the
/// strip, with nothing loaded twice. Moving its hostView between superviews
/// is exactly what switching tabs already does on both engines.
///
/// The panel is a view inside the window's web-content container, never a
/// child window: ordering a window on screen while the omnibox has focus
/// crashes AppKit (see CLAUDE.md), and a view needs no focus juggling.
///
/// The covered tab's hostView is taken out of the container while the peek
/// shows, and a still of it stands in behind the dimming. Nothing may be
/// drawn over a CEF page: its surface paints over overlapping AppKit views
/// in some window layouts (see CLAUDE.md), so a panel layered above it can
/// simply not appear. Detaching is what switching tabs already does, so the
/// page stays loaded and comes back as it was. Switching tabs while peeking
/// dismisses the peek -- see tabLifecycleEvent.
///
/// One per BrowserWindowController.
final class LinkPeekController: TabLifecycleObserver {
    private weak var windowController: BrowserWindowController?
    private weak var container: NSView?

    private(set) var peekTab: Tab?
    /// The active tab the peek opened over, detached until the peek goes.
    private weak var coveredTab: Tab?
    private var overlay: LinkPeekOverlayView?
    private var keyMonitor: Any?
    /// The peeked page should take keyboard focus as soon as its engine view
    /// exists, which on CEF can be a little after createBrowserIfNeeded.
    private var wantsPageFocus = false

    init(windowController: BrowserWindowController, container: NSView) {
        self.windowController = windowController
        self.container = container
        TabLifecycleCenter.shared.addObserver(self)
    }

    var isShowing: Bool { peekTab != nil }

    /// Called from BrowserWindowController.show(): the gesture monitor is
    /// app-wide and only needs a window to exist.
    func windowDidShow() {
        LinkPeekGestureMonitor.shared.installIfNeeded()
        Self.runTestHookIfRequested(on: self)
    }

    // MARK: - Opening

    /// Peeks at `url`, replacing whatever the panel was showing.
    func show(url: String) {
        if let peekTab {
            peekTab.load(url: url)
            return
        }
        guard let windowController else { return }
        let tab = Tab(
            profileName: windowController.profile.name,
            profileId: windowController.profile.id,
            initialURL: url,
            isPrivate: windowController.isPrivate)
        present(tab)
    }

    /// A new-window request from `tab`, claimed as a peek when it follows a
    /// ⌥⇧-click in this window. Returns whether it was claimed.
    func takeNewWindowRequest(url: String, from tab: Tab) -> Bool {
        guard claimsGesture(from: tab) else { return false }
        show(url: url)
        return true
    }

    /// The same for an engine-created popup (a ⌥⇧-clicked target="_blank"
    /// link): the popup keeps its opener link, which sign-in flows rely on.
    ///
    /// Never for a popup the peeked page itself opens: replacing the peek
    /// with it would close its opener, which is the page waiting on it.
    func takePopup(_ popup: Tab, from tab: Tab) -> Bool {
        guard tab !== peekTab, claimsGesture(from: tab) else { return false }
        popup.needsInitialOmniboxFocus = false
        present(popup)
        return true
    }

    private func claimsGesture(from tab: Tab) -> Bool {
        guard LinkPeekPreference.isEnabled,
              let windowController, let window = windowController.window,
              tab === windowController.activeTab || tab === peekTab
        else { return false }
        return LinkPeekGestureMonitor.shared.consume(windowNumber: window.windowNumber)
    }

    private func present(_ tab: Tab) {
        guard let windowController, let container else { return }
        if peekTab != nil { dismiss() }

        tab.needsInitialOmniboxFocus = false
        tab.delegate = windowController
        peekTab = tab

        let overlay = LinkPeekOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClickOutside = { [weak self] in self?.dismiss() }
        overlay.onClose = { [weak self] in self?.dismiss() }
        overlay.onOpenAsTab = { [weak self] in self?.openAsTab() }
        if let covered = windowController.activeTab, covered.hostView.superview === container {
            overlay.setBackdrop(Self.snapshot(of: covered.hostView))
            covered.hostView.removeFromSuperview()
            coveredTab = covered
        }
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.embed(tab.hostView)
        overlay.update(title: tab.displayTitle, urlString: tab.urlString)
        self.overlay = overlay

        // Per-tab plumbing (page messages above all) is wired on .opened;
        // posting it now means the peeked page gets it from its first load.
        // Posting it again when the tab joins the strip is harmless: every
        // observer's .opened handling is idempotent.
        TabLifecycleCenter.shared.post(.opened, tab: tab, in: windowController)
        tab.createBrowserIfNeeded()
        installKeyMonitor()
        wantsPageFocus = !focusPage(of: tab)
    }

    // MARK: - Closing and keeping

    /// Puts the peek away and closes its page.
    func dismiss() {
        guard let tab = peekTab else { return }
        tearDownPanel()
        tab.close()
        if let windowController {
            TabLifecycleCenter.shared.post(.closed, tab: tab, in: windowController)
            if let active = windowController.activeTab { focusPage(of: active) }
        }
    }

    /// Moves the peeked page into the tab strip, next to the current tab.
    func openAsTab() {
        guard let tab = peekTab, let windowController else { return }
        tearDownPanel()
        windowController.adoptTab(tab, makeActive: true)
        focusPage(of: tab)
    }

    private func tearDownPanel() {
        removeKeyMonitor()
        wantsPageFocus = false
        peekTab?.hostView.removeFromSuperview()
        overlay?.removeFromSuperview()
        overlay = nil
        peekTab = nil
        restoreCoveredTab()
    }

    /// Puts the covered tab's view back, unless another tab has since taken
    /// the content area (which is what dismissed the peek).
    private func restoreCoveredTab() {
        defer { coveredTab = nil }
        guard let covered = coveredTab, let container, covered === windowController?.activeTab,
              covered.hostView.superview == nil else { return }
        covered.hostView.frame = container.bounds
        covered.hostView.autoresizingMask = [.width, .height]
        container.addSubview(covered.hostView, positioned: .below, relativeTo: nil)
    }

    private static func snapshot(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Relayed from BrowserWindowController's TabDelegate

    func peekedTabDidChangeDisplayState(_ tab: Tab) {
        guard tab === peekTab else { return }
        overlay?.update(title: tab.displayTitle, urlString: tab.urlString)
        if wantsPageFocus {
            wantsPageFocus = !focusPage(of: tab)
        }
    }

    /// Gives keyboard focus to the engine's view inside `tab`. Returns false
    /// while that view does not exist yet.
    @discardableResult
    private func focusPage(of tab: Tab) -> Bool {
        guard let window = windowController?.window,
              let view = Self.firstFocusableView(in: tab.devTools.pageView) else { return false }
        return window.makeFirstResponder(view)
    }

    private static func firstFocusableView(in root: NSView) -> NSView? {
        for subview in root.subviews where !subview.isHidden {
            if subview.acceptsFirstResponder { return subview }
            if let found = firstFocusableView(in: subview) { return found }
        }
        return nil
    }

    func peekedTabDidRequestClose(_ tab: Tab) {
        guard tab === peekTab else { return }
        dismiss()
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard controller === windowController, isShowing, tab !== peekTab else { return }
        // Another tab taking the content area (a switch, or the active tab
        // closing) would bury the panel under its hostView.
        if case .becameActive = event {
            dismiss()
        }
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing, event.window === self.windowController?.window else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53, flags.isEmpty, !self.pageOrTextHasFocus(in: event.window) {
                self.dismiss()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Escape belongs to whatever has focus when that is the peeked page (a
    /// modal of its own, an IME composition) or a native text field such as
    /// the omnibox. It closes the peek only from the panel itself -- after a
    /// click on its header, say -- or when nothing else wants it.
    private func pageOrTextHasFocus(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if (responder as? NSTextView)?.isFieldEditor == true { return true }
        guard let view = responder as? NSView, let pageHost = peekTab?.hostView else { return false }
        return view.isDescendant(of: pageHost)
    }

    // MARK: - Test hook

    private static var testHookRan = false

    /// `--test-link-peek <url>`: peeks at `url` over the first window's page
    /// shortly after launch, so an agent can screenshot the panel without
    /// driving the UI. Once per process.
    private static func runTestHookIfRequested(on controller: LinkPeekController) {
        let args = CommandLine.arguments
        guard !testHookRan, let index = args.firstIndex(of: "--test-link-peek"), index + 1 < args.count else { return }
        testHookRan = true
        let url = args[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak controller] in
            controller?.show(url: url)
        }
    }
}
