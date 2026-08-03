import AppKit

/// Conformed by every Settings pane controller so SettingsWindowController
/// can size the window to fit whichever pane is currently selected (see
/// resizeWindowForSelectedTab) instead of sharing one fixed window height
/// across all six tabs regardless of how little or how much each one needs.
protocol SettingsPaneController: AnyObject {
    var view: NSView { get }
    var preferredContentHeight: CGFloat { get }
}

extension SettingsPaneController {
    /// Default for panes built around a scrollable table that stretches to
    /// fill whatever height it's given (Routing Rules, Profiles, Privacy,
    /// Autofill's Passwords/Cards/Addresses) -- these don't have one
    /// "natural" size the way a fixed handful of controls does, so this
    /// just picks a comfortable default that shows a handful of rows
    /// without the window feeling cramped. Panes with no such filler
    /// (General, Start Page) override this with an exact computed value.
    var preferredContentHeight: CGFloat { 400 }
}

/// The app's "Settings…" window (⌘,), standard macOS placement in the app
/// menu. Hosts six sections in an NSTabView: "General" (global preferences
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
/// before browser-ojh.2 added cards/addresses alongside it). This
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
    private let tabView = NSTabView()

    /// The vertical space the window needs beyond a pane's own content --
    /// the title bar plus NSTabView's tab-label strip. Measured once,
    /// empirically, right after the first pane is laid out (see
    /// measureChromeOverheadHeight), rather than hardcoded: NSTabView
    /// resizes the selected tab item's view to fill its content area as
    /// soon as the item is added, so the gap between that resized size and
    /// the window's content height at that moment *is* this overhead,
    /// exactly, regardless of tab style or OS version.
    private var chromeOverheadHeight: CGFloat = 0

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        super.init(window: window)
        window.delegate = self
        // tabView.delegate is assigned only after setUpViews() below, not
        // before: NSTabView auto-selects the first item as soon as it's
        // added, which fires tabView(_:didSelect:) synchronously, mid-
        // setUpViews() -- if the delegate were already wired up, that would
        // trigger a premature resizeWindowForSelectedTab() call before
        // chromeOverheadHeight has ever been measured (still its zero
        // default) and before tabView itself has even been added to
        // contentView, corrupting the window/tabView size relationship
        // from the very start.
        setUpViews()
        tabView.delegate = self
        measureChromeOverheadHeight()
        resizeWindow(for: tabView.selectedTabViewItem, animated: false)
        window.center()
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
        tabView.selectTabViewItem(withIdentifier: parts[0])
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
        generalItem.view = generalPane.view

        let routingItem = NSTabViewItem(identifier: "routing-rules")
        routingItem.label = "Routing Rules"
        routingItem.view = routingRulesPane.view

        let profilesItem = NSTabViewItem(identifier: "profiles")
        profilesItem.label = "Profiles"
        profilesItem.view = profilesPane.view

        let privacyItem = NSTabViewItem(identifier: "privacy")
        privacyItem.label = "Privacy"
        privacyItem.view = privacyPane.view

        let startPageItem = NSTabViewItem(identifier: "start-page")
        startPageItem.label = "Start Page"
        startPageItem.view = startPagePane.view

        let autofillItem = NSTabViewItem(identifier: "autofill")
        autofillItem.label = "Autofill"
        autofillItem.view = autofillPane.view

        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(routingItem)
        tabView.addTabViewItem(profilesItem)
        tabView.addTabViewItem(privacyItem)
        tabView.addTabViewItem(startPageItem)
        tabView.addTabViewItem(autofillItem)
        contentView.addSubview(tabView)
    }

    // MARK: - Per-tab window sizing

    /// NSTabView resizes the selected item's view to fill its content area
    /// synchronously as items are added -- generalItem is the first item
    /// added above, so by now tabView has already stretched (or shrunk)
    /// generalPane.view from its authored height to whatever this window's
    /// initial content height allows. The difference is exactly the
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
        default: return nil
        }
    }

    /// Resizes the window to fit the given tab's own natural height, keeping
    /// the window's top edge and width fixed -- standard macOS preferences
    /// behavior (see e.g. Safari/Mail Settings), so switching tabs grows or
    /// shrinks the window from the bottom rather than every tab sharing one
    /// fixed size regardless of its content.
    ///
    /// Called from tabView(_:willSelect:) -- BEFORE NSTabView swaps in the
    /// new tab's view -- rather than didSelect (after). NSTabView tiles
    /// whichever view it swaps in to fit the *current* content rect at that
    /// moment; resizing only after the swap (on didSelect) meant a pane
    /// went from its pristine authored size to whatever the *previous*
    /// tab's size happened to be, and back again a moment later. For a
    /// pane whose scroll view has no slack to give (e.g. Routing Rules,
    /// authored with zero spare height), shrinking through a much smaller
    /// intermediate size clamps that scroll view's height at 0, and the
    /// following grow-back then overshoots -- confirmed via a real
    /// scratch-launch screenshot where the oversized, clipped scroll view
    /// ended up painted over the "Routing Rules" header. Resizing first
    /// means the incoming view is tiled directly from its authored size to
    /// its own preferredContentHeight, which are defined to be the same
    /// value, so no intermediate size -- and no autoresizing-mask math --
    /// happens at all.
    private func resizeWindow(for tabViewItem: NSTabViewItem?, animated: Bool) {
        guard let window, let contentView = window.contentView else { return }
        let preferredHeight = pane(for: tabViewItem)?.preferredContentHeight ?? 400
        let desiredContentRect = NSRect(x: 0, y: 0, width: contentView.bounds.width, height: preferredHeight + chromeOverheadHeight)
        let desiredWindowFrame = window.frameRect(forContentRect: desiredContentRect)

        var newFrame = window.frame
        let deltaHeight = desiredWindowFrame.height - newFrame.height
        newFrame.size.height = desiredWindowFrame.height
        newFrame.origin.y -= deltaHeight
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
