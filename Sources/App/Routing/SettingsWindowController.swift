import AppKit

/// The app's "Settings…" window (⌘,), standard macOS placement in the app
/// menu. Hosts two sections in an NSTabView: "Routing Rules" (main/first
/// tab, per Brady's original request -- see RoutingRulesPaneController) and
/// "Profiles" (create/rename/recolor/delete -- see ProfilesPaneController).
/// This controller just owns the window and composes the two panes; all the
/// section-specific logic lives in their own controllers.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let routingRulesPane = RoutingRulesPaneController()
    private let profilesPane = ProfilesPaneController()

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
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView(frame: contentView.bounds)
        tabView.autoresizingMask = [.width, .height]

        let routingItem = NSTabViewItem(identifier: "routing-rules")
        routingItem.label = "Routing Rules"
        routingItem.view = routingRulesPane.view

        let profilesItem = NSTabViewItem(identifier: "profiles")
        profilesItem.label = "Profiles"
        profilesItem.view = profilesPane.view

        tabView.addTabViewItem(routingItem)
        tabView.addTabViewItem(profilesItem)
        contentView.addSubview(tabView)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- this is a singleton, kept alive for the
        // app's lifetime, just hidden when closed.
    }
}
