import AppKit

/// Conformed by every Settings pane controller so SettingsWindowController
/// can size the window to fit whichever pane is currently selected (see
/// resizeWindow(for:animated:)), and so each pane's SettingsPaneScrollView
/// knows how tall the pane's content is before it has to scroll.
protocol SettingsPaneController: AnyObject {
    var view: NSView { get }
    /// The height the pane's content needs at `width`: the window grows to
    /// this when the pane is selected, and below it the pane scrolls rather
    /// than being squeezed.
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat
}

extension SettingsPaneController {
    /// Default for panes built around a scrollable table that stretches to
    /// fill whatever height it's given (Routing Rules, Profiles, Autofill's
    /// sections) -- these don't have one "natural" size the way a fixed
    /// handful of controls does, so this is the height they were laid out
    /// at, which shows a handful of rows without the window feeling cramped.
    /// Panes with no such filler override it with their real content height.
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { 400 }
}

/// The app's "Settings…" window (⌘,), standard macOS placement in the app
/// menu. Hosts seven sections in an NSTabView: "General" (global preferences
/// not tied to any one profile -- currently just the omnibox display mode,
/// see GeneralPaneController, browser-0y1), "Routing Rules" (per Brady's
/// original request -- see RoutingRulesPaneController), "Profiles"
/// (create/rename/recolor/delete -- see ProfilesPaneController), "Privacy"
/// (per-profile ad/tracker blocking -- see PrivacyPaneController,
/// browser-12m.5.1), "Start Page" (per-profile start-page customization --
/// see StartPageSettingsPaneController, browser-5kq.3/.4), and "Autofill"
/// (per-profile saved passwords/cards/addresses as three inner sub-tabs,
/// Touch-ID-gated reveal for the secret bits -- see AutofillPaneController,
/// browser-ojh.1/.2; this used to be a standalone "Passwords" top-level tab
/// before browser-ojh.2 added cards/addresses alongside it), and "Safari"
/// (the ongoing Safari history sync -- see SafariSyncPaneController). This
/// controller just owns the window and composes the panes; all the
/// section-specific logic lives in their own controllers.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    static let shared = SettingsWindowController()

    private let generalPane = GeneralPaneController()
    private let routingRulesPane = RoutingRulesPaneController()
    private let profilesPane = ProfilesPaneController()
    private let privacyPane = PrivacyPaneController()
    private let startPagePane = StartPageSettingsPaneController()
    private let autofillPane = AutofillPaneController()
    private let safariSyncPane = SafariSyncPaneController()
    private let extensionsPane = ExtensionsPaneController()
    private let tabView = NSTabView()
    /// Kept alive for the window's lifetime -- see WindowFrameMemory.
    private var frameMemory: WindowFrameMemory?

    /// The vertical space the window needs beyond a pane's own content --
    /// the title bar plus NSTabView's tab-label strip. Measured once,
    /// empirically, right after the first pane is laid out (see
    /// measureChromeOverheadHeight), rather than hardcoded: NSTabView
    /// resizes the selected tab item's view to fill its content area as
    /// soon as the item is added, so the gap between that resized size and
    /// the window's content height at that moment *is* this overhead,
    /// exactly, regardless of tab style or OS version.
    private var chromeOverheadHeight: CGFloat = 0

    /// Kept clear between a fitted window and the edges of the visible
    /// screen, so a very tall pane never produces a window touching the
    /// menu bar or the Dock.
    private static let screenMargin: CGFloat = 40

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        // The panes' fixed-width rows (e.g. General's homepage field and
        // button) are laid out for this default width and would overlap
        // any narrower. Height needs no real floor, since each pane scrolls.
        window.contentMinSize = NSSize(width: 580, height: 220)
        super.init(window: window)
        window.delegate = self
        // tabView.delegate is assigned only after setUpViews() below, not
        // before: NSTabView auto-selects the first item as soon as it's
        // added, which fires tabView(_:didSelect:) synchronously, mid-
        // setUpViews() -- if the delegate were already wired up, that would
        // trigger a premature resizeWindow(for:animated:) call before
        // chromeOverheadHeight has ever been measured (still its zero
        // default) and before tabView itself has even been added to
        // contentView, corrupting the window/tabView size relationship
        // from the very start.
        setUpViews()
        tabView.delegate = self
        measureChromeOverheadHeight()
        resizeWindow(for: tabView.selectedTabViewItem, animated: false)
        window.center()
        // After the initial sizing above, so a remembered frame wins over
        // the freshly measured one rather than being overwritten by it.
        frameMemory = WindowFrameMemory(window: window, name: "settings")
        // A remembered frame keeps its position and width, but its height is
        // refitted to the selected pane: a height saved before a pane grew
        // would otherwise open with that pane's lower rows out of view.
        resizeWindow(for: tabView.selectedTabViewItem, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        generalPane.reload()
        routingRulesPane.reload()
        profilesPane.reload()
        privacyPane.reload()
        startPagePane.reload()
        autofillPane.reload()
        safariSyncPane.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens Settings already on the "Start Page" tab -- reached from the
    /// start page's own gear button (see Tab.engineTabDidChangeURL's
    /// StartPageRenderer.settingsFragment interception), not just the menu.
    func showStartPageTab() {
        showTab(identifier: "start-page")
    }

    /// Also the `--show-settings-tab <identifier>` launch argument's entry
    /// point (see CommandLineArgs.showSettingsTabIdentifier) -- opens
    /// Settings on a specific tab with no synthetic click/keystroke, so an
    /// agent can screenshot it per AGENTS.md's UI verification protocol.
    /// `identifier` may be a compound "autofill:<sub-identifier>" (e.g.
    /// "autofill:autofill-cards") to additionally select one of
    /// AutofillPaneController's own inner Passwords/Cards/Addresses tabs,
    /// which otherwise always shows whichever one Passwords leaves selected.
    func showTab(identifier: String) {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        // NSTabView raises on an identifier it has no item for, and this is
        // reached from a launch argument, so an unknown name must not take
        // the app down before it has finished launching.
        guard let tabIdentifier = parts.first,
              tabView.indexOfTabViewItem(withIdentifier: tabIdentifier) != NSNotFound else {
            NSLog("Settings has no tab named '%@'; showing the current one", identifier)
            show()
            return
        }
        tabView.selectTabViewItem(withIdentifier: tabIdentifier)
        if parts[0] == "autofill", parts.count == 2 {
            autofillPane.selectSubTab(identifier: parts[1])
        }
        show()
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }

        tabView.frame = contentView.bounds
        tabView.autoresizingMask = [.width, .height]

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = SettingsPaneScrollView(pane: generalPane)

        let routingItem = NSTabViewItem(identifier: "routing-rules")
        routingItem.label = "Routing Rules"
        routingItem.view = SettingsPaneScrollView(pane: routingRulesPane)

        let profilesItem = NSTabViewItem(identifier: "profiles")
        profilesItem.label = "Profiles"
        profilesItem.view = SettingsPaneScrollView(pane: profilesPane)

        let privacyItem = NSTabViewItem(identifier: "privacy")
        privacyItem.label = "Privacy"
        privacyItem.view = SettingsPaneScrollView(pane: privacyPane)

        let startPageItem = NSTabViewItem(identifier: "start-page")
        startPageItem.label = "Start Page"
        startPageItem.view = SettingsPaneScrollView(pane: startPagePane)

        let autofillItem = NSTabViewItem(identifier: "autofill")
        autofillItem.label = "Autofill"
        autofillItem.view = SettingsPaneScrollView(pane: autofillPane)

        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(routingItem)
        tabView.addTabViewItem(profilesItem)
        tabView.addTabViewItem(privacyItem)
        tabView.addTabViewItem(startPageItem)
        let safariSyncItem = NSTabViewItem(identifier: "safari-sync")
        safariSyncItem.label = "Safari"
        safariSyncItem.view = SettingsPaneScrollView(pane: safariSyncPane)

        tabView.addTabViewItem(autofillItem)
        tabView.addTabViewItem(safariSyncItem)
        if ActiveEngine.capabilities.webExtensions {
            let extensionsItem = NSTabViewItem(identifier: "extensions")
            extensionsItem.label = "Extensions"
            extensionsItem.view = SettingsPaneScrollView(pane: extensionsPane)
            tabView.addTabViewItem(extensionsItem)
        }
        contentView.addSubview(tabView)
    }

    // MARK: - Per-tab window sizing

    /// NSTabView resizes the selected item's view to fill its content area
    /// synchronously as items are added -- generalItem is the first item
    /// added above, so by now tabView has already stretched (or shrunk)
    /// General's scroll view from its authored height to whatever this
    /// window's initial content height allows. The difference is exactly the
    /// non-pane chrome (title bar + tab-label strip) this window always
    /// needs on top of a pane's own preferredContentHeight.
    private func measureChromeOverheadHeight() {
        guard let contentView = window?.contentView, let itemView = tabView.selectedTabViewItem?.view else { return }
        chromeOverheadHeight = max(0, contentView.bounds.height - itemView.frame.height)
    }

    private func pane(for tabViewItem: NSTabViewItem?) -> SettingsPaneController? {
        switch tabViewItem?.identifier as? String {
        case "general": return generalPane
        case "routing-rules": return routingRulesPane
        case "profiles": return profilesPane
        case "privacy": return privacyPane
        case "start-page": return startPagePane
        case "autofill": return autofillPane
        case "safari-sync": return safariSyncPane
        case "extensions": return extensionsPane
        default: return nil
        }
    }

    /// Resizes the window to fit the given tab's own content height, keeping
    /// the window's top-left corner and width fixed -- standard macOS
    /// settings behavior (see System Settings, Safari/Mail Settings), so
    /// switching tabs grows or shrinks the window from the bottom. The height
    /// is capped to the visible screen; a pane taller than that scrolls
    /// inside its SettingsPaneScrollView. If the fitted window would run off
    /// the bottom of the screen, it moves up just enough to stay on it.
    ///
    /// Called from tabView(_:willSelect:), before NSTabView swaps in the new
    /// tab's view, so the incoming pane is tiled once, at its final size.
    private func resizeWindow(for tabViewItem: NSTabViewItem?, animated: Bool) {
        guard let window, let contentView = window.contentView else { return }
        // Every tab's view shares the tab view's one content area.
        let paneWidth = tabView.contentRect.width
        let preferredHeight = pane(for: tabViewItem)?.preferredContentHeight(forWidth: paneWidth) ?? 400
        let desiredContentRect = NSRect(x: 0, y: 0, width: contentView.bounds.width, height: preferredHeight + chromeOverheadHeight)
        var desiredHeight = window.frameRect(forContentRect: desiredContentRect).height

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        if let visible {
            desiredHeight = min(desiredHeight, visible.height - Self.screenMargin)
        }
        desiredHeight = max(desiredHeight, window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).height)

        var newFrame = window.frame
        newFrame.origin.y = newFrame.maxY - desiredHeight
        newFrame.size.height = desiredHeight
        if let visible, newFrame.minY < visible.minY {
            newFrame.origin.y = visible.minY
        }
        guard newFrame != window.frame else { return }
        window.setFrame(newFrame, display: true, animate: animated)
    }

    // MARK: - NSTabViewDelegate

    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        resizeWindow(for: tabViewItem, animated: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- this is a singleton, kept alive for the
        // app's lifetime, just hidden when closed.
    }
}
