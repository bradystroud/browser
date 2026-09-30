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
    /// fill whatever height it's given (Links, Profiles, Passwords, Autofill)
    /// -- these don't have one "natural" size the way a fixed handful of
    /// controls does, so this is a height that shows a handful of rows
    /// without the window feeling cramped. Panes with no such filler
    /// override it with their real content height.
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { 400 }
}

/// The app's "Settings…" window (⌘,), in the macOS settings-window style:
/// a toolbar of panes (NSTabViewController's `.toolbar` style), the window
/// titled after the selected pane, and the window's height refitted to each
/// pane as it is selected. This controller owns the window and composes the
/// panes; each pane's own logic lives in its controller.
///
/// A toolbar rather than a sidebar: there are at most nine panes, which fit
/// across a settings window the way Safari's own do, and a toolbar window
/// can take each pane's height -- a sidebar window would carry the sidebar's
/// height even for a pane of three rows.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// One Settings pane: its stable identifier (what `--show-settings-tab`
    /// and the remembered pane use), toolbar title and SF Symbol.
    private struct PaneInfo {
        let identifier: String
        let title: String
        let symbol: String
        let controller: SettingsPaneController
    }

    private let generalPane = GeneralPaneController()
    private let linksPane = RoutingRulesPaneController()
    private let profilesPane = ProfilesPaneController()
    private let privacyPane = PrivacyPaneController()
    private let startPagePane = StartPageSettingsPaneController()
    private let passwordsPane = PasswordsPaneController()
    private let autofillPane = AutofillPaneController()
    private let safariSyncPane = SafariSyncPaneController()
    private let extensionsPane = ExtensionsPaneController()
    private let tabViewController = SettingsTabViewController()
    private var panes: [PaneInfo] = []
    /// Kept alive for the window's lifetime -- see WindowFrameMemory.
    private var frameMemory: WindowFrameMemory?

    /// The last pane shown, restored the next time Settings opens.
    private static let lastPaneKey = "SettingsWindow.lastPane"

    /// Wide enough for every pane's toolbar item side by side, and for the
    /// form panes' fixed label and control columns (see SettingsForm).
    private static let minimumContentWidth: CGFloat = 680

    /// Kept clear between a fitted window and the edges of the visible
    /// screen, so a very tall pane never produces a window touching the
    /// menu bar or the Dock.
    private static let screenMargin: CGFloat = 40

    /// Earlier names for panes, still accepted by `--show-settings-tab`.
    private static let paneAliases: [String: String] = [
        "routing-rules": "links",
        "routing": "links",
        "safari-sync": "safari",
        "autofill-passwords": "passwords",
    ]

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.minimumContentWidth, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.toolbarStyle = .preference
        // Panes swap in and out, and a form's rows appear and hide, so Tab
        // must follow what is on screen now, not what was there first.
        window.autorecalculatesKeyViewLoop = true
        // Height needs no real floor, since each pane scrolls.
        window.contentMinSize = NSSize(width: Self.minimumContentWidth, height: 220)
        super.init(window: window)
        window.delegate = self

        panes = [
            PaneInfo(identifier: "general", title: "General", symbol: "gearshape", controller: generalPane),
            PaneInfo(identifier: "links", title: "Links", symbol: "link", controller: linksPane),
            PaneInfo(identifier: "profiles", title: "Profiles", symbol: "person.2", controller: profilesPane),
            PaneInfo(identifier: "privacy", title: "Privacy", symbol: "hand.raised", controller: privacyPane),
            PaneInfo(identifier: "start-page", title: "Start Page", symbol: "square.grid.2x2", controller: startPagePane),
            PaneInfo(identifier: "passwords", title: "Passwords", symbol: "key", controller: passwordsPane),
            PaneInfo(identifier: "autofill", title: "Autofill", symbol: "person.text.rectangle", controller: autofillPane),
            PaneInfo(identifier: "safari", title: "Safari", symbol: "safari", controller: safariSyncPane),
        ]
        if ActiveEngine.capabilities.webExtensions {
            panes.append(PaneInfo(identifier: "extensions", title: "Extensions", symbol: "puzzlepiece.extension", controller: extensionsPane))
        }

        tabViewController.tabStyle = .toolbar
        for pane in panes {
            let child = SettingsPaneViewController(pane: pane.controller)
            child.title = pane.title
            let item = NSTabViewItem(viewController: child)
            item.identifier = pane.identifier
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabViewController.addTabViewItem(item)
        }
        if let saved = AppPreferencesStore.current.string(forKey: Self.lastPaneKey),
           let index = panes.firstIndex(where: { $0.identifier == saved }) {
            tabViewController.selectedTabViewItemIndex = index
        }
        // Wired up only now: selecting the remembered pane above must not
        // try to fit a window that has no content yet.
        tabViewController.onWillSelect = { [weak self] item in
            self?.resizeWindow(for: item, animated: true)
        }
        tabViewController.onDidSelect = { [weak self] item in
            self?.paneDidChange(to: item)
        }

        window.contentViewController = tabViewController
        window.setContentSize(NSSize(width: Self.minimumContentWidth, height: 500))
        paneDidChange(to: tabViewController.tabView.selectedTabViewItem)
        resizeWindow(for: tabViewController.tabView.selectedTabViewItem, animated: false)
        window.center()
        // After the initial sizing above, so a remembered frame wins over
        // the freshly measured one rather than being overwritten by it.
        frameMemory = WindowFrameMemory(window: window, name: "settings")
        // A remembered frame keeps its position, but its height is refitted
        // to the selected pane (a height saved before a pane grew would
        // otherwise open with that pane's lower rows out of view), and a
        // width saved when the window could be narrower is widened.
        resizeWindow(for: tabViewController.tabView.selectedTabViewItem, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        generalPane.reload()
        linksPane.reload()
        profilesPane.reload()
        privacyPane.reload()
        startPagePane.reload()
        passwordsPane.reload()
        autofillPane.reload()
        safariSyncPane.reload()
        // The toolbar is only in place once the window is, so the fit made
        // at init may not have counted it.
        resizeWindow(for: tabViewController.tabView.selectedTabViewItem, animated: false)
        window?.makeKeyAndOrderFront(nil)
        resizeWindow(for: tabViewController.tabView.selectedTabViewItem, animated: false)
        AppActivation.activate()
    }

    /// Opens Settings already on the "Start Page" pane -- reached from the
    /// start page's own gear button (see Tab.engineTabDidChangeURL's
    /// StartPageRenderer.settingsFragment interception), not just the menu.
    func showStartPageTab() {
        showTab(identifier: "start-page")
    }

    /// Also the `--show-settings-tab <identifier>` launch argument's entry
    /// point (see CommandLineArgs.showSettingsTabIdentifier) -- opens
    /// Settings on a specific pane with no synthetic click/keystroke, so an
    /// agent can screenshot it per AGENTS.md's UI verification protocol.
    /// `identifier` is a pane identifier (see `panes`) or one of its older
    /// names (`paneAliases`). "autofill:<section>" (e.g. "autofill:cards")
    /// also picks one of the Autofill pane's sections; "autofill:passwords",
    /// from when Passwords lived inside Autofill, opens the Passwords pane.
    func showTab(identifier: String) {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        var paneIdentifier = parts.first ?? ""
        var section = parts.count == 2 ? parts[1] : nil
        if paneIdentifier == "autofill", let requested = section,
           AutofillPaneController.sectionName(from: requested) == nil,
           requested.hasSuffix("passwords") {
            paneIdentifier = "passwords"
            section = nil
        }
        paneIdentifier = Self.paneAliases[paneIdentifier] ?? paneIdentifier
        if paneIdentifier.hasPrefix("autofill-"), AutofillPaneController.sectionName(from: paneIdentifier) != nil {
            section = paneIdentifier
            paneIdentifier = "autofill"
        }
        guard let index = panes.firstIndex(where: { $0.identifier == paneIdentifier }) else {
            NSLog("Settings has no pane named '%@'; showing the current one", identifier)
            show()
            return
        }
        tabViewController.selectedTabViewItemIndex = index
        if paneIdentifier == "autofill", let section {
            autofillPane.selectSubTab(identifier: section)
        }
        show()
    }

    // MARK: - Pane changes

    private func paneInfo(for item: NSTabViewItem?) -> PaneInfo? {
        guard let identifier = item?.identifier as? String else { return nil }
        return panes.first { $0.identifier == identifier }
    }

    private func paneDidChange(to item: NSTabViewItem?) {
        guard let info = paneInfo(for: item) else { return }
        window?.title = info.title
        AppPreferencesStore.current.set(info.identifier, forKey: Self.lastPaneKey)
    }

    // MARK: - Per-pane window sizing

    /// Resizes the window to fit the given pane's own content height,
    /// keeping the window's top-left corner fixed -- standard macOS settings
    /// behavior (see System Settings, Safari/Mail Settings), so switching
    /// panes grows or shrinks the window from the bottom. The height is
    /// capped to the visible screen; a pane taller than that scrolls inside
    /// its SettingsPaneScrollView. If the fitted window would run off the
    /// bottom of the screen, it moves up just enough to stay on it.
    ///
    /// Called before NSTabViewController swaps in the new pane's view, so
    /// the incoming pane is tiled once, at its final size.
    private func resizeWindow(for item: NSTabViewItem?, animated: Bool) {
        guard let window, let contentView = window.contentView else { return }
        let paneWidth = max(contentView.bounds.width, Self.minimumContentWidth)
        let preferredHeight = paneInfo(for: item)?.controller.preferredContentHeight(forWidth: paneWidth) ?? 400
        // Everything the window has above its content view -- the title bar
        // and the pane toolbar -- measured live, since the toolbar only
        // appears once the window is on screen.
        let chromeHeight = window.frame.height - contentView.frame.height
        var desiredHeight = preferredHeight + chromeHeight
        let minimumHeight = window.contentMinSize.height + chromeHeight

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        if let visible {
            desiredHeight = min(desiredHeight, visible.height - Self.screenMargin)
        }
        desiredHeight = max(desiredHeight, minimumHeight).rounded(.up)

        var newFrame = window.frame
        newFrame.origin.y = newFrame.maxY - desiredHeight
        newFrame.size.height = desiredHeight
        let minimumFrameWidth = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.minimumContentWidth, height: 1)).width
        newFrame.size.width = max(newFrame.size.width, minimumFrameWidth)
        if let visible, newFrame.minY < visible.minY {
            newFrame.origin.y = visible.minY
        }
        guard newFrame != window.frame else { return }
        window.setFrame(newFrame, display: true, animate: animated && window.isVisible)
    }
}

/// Hosts one pane in the Settings toolbar: its view is the pane wrapped in a
/// SettingsPaneScrollView.
private final class SettingsPaneViewController: NSViewController {
    private let pane: SettingsPaneController

    init(pane: SettingsPaneController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = SettingsPaneScrollView(pane: pane)
    }
}

/// NSTabViewController is its tab view's delegate; this passes selection
/// changes on to SettingsWindowController.
private final class SettingsTabViewController: NSTabViewController {
    var onWillSelect: ((NSTabViewItem?) -> Void)?
    var onDidSelect: ((NSTabViewItem?) -> Void)?

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        onWillSelect?(tabViewItem)
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onDidSelect?(tabViewItem)
    }
}
