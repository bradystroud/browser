import AppKit

/// The app's "Settings…" window (⌘,), standard macOS placement in the app
/// menu. Hosts five sections in an NSTabView: "Routing Rules" (main/first
/// tab, per Brady's original request -- see RoutingRulesPaneController),
/// "Profiles" (create/rename/recolor/delete -- see ProfilesPaneController),
/// "Privacy" (per-profile ad/tracker blocking -- see
/// PrivacyPaneController, browser-12m.5.1), "Start Page" (per-profile
/// start-page customization -- see StartPageSettingsPaneController,
/// browser-5kq.3/.4), and "Autofill" (per-profile saved passwords/cards/
/// addresses as three inner sub-tabs, Touch-ID-gated reveal for the
/// secret bits -- see AutofillPaneController, browser-ojh.1/.2; this used
/// to be a standalone "Passwords" top-level tab before browser-ojh.2 added
/// cards/addresses alongside it). This controller just owns the window and
/// composes the panes; all the section-specific logic lives in their own
/// controllers.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let routingRulesPane = RoutingRulesPaneController()
    private let profilesPane = ProfilesPaneController()
    private let privacyPane = PrivacyPaneController()
    private let startPagePane = StartPageSettingsPaneController()
    private let autofillPane = AutofillPaneController()
    private let tabView = NSTabView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
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
        show()
        tabView.selectTabViewItem(withIdentifier: "start-page")
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }

        tabView.frame = contentView.bounds
        tabView.autoresizingMask = [.width, .height]

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

        tabView.addTabViewItem(routingItem)
        tabView.addTabViewItem(profilesItem)
        tabView.addTabViewItem(privacyItem)
        tabView.addTabViewItem(startPageItem)
        tabView.addTabViewItem(autofillItem)
        contentView.addSubview(tabView)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- this is a singleton, kept alive for the
        // app's lifetime, just hidden when closed.
    }
}
