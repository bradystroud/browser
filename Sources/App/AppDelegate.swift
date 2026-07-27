import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Not private: BrowserWindowController reaches this via `NSApp.delegate
    // as? AppDelegate` to refresh the History/Bookmarks menus' per-profile
    // dynamic sections after a visit/bookmark change -- see
    // rebuildRecentHistory(for:)/rebuildBookmarksMenu(for:).
    let mainMenuBuilder = MainMenuBuilder()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Build the menu bar before any window opens -- there's no
        // MainMenu.xib in this project, see MainMenuBuilder.
        NSApp.mainMenu = mainMenuBuilder.build()
        NSApp.windowsMenu = mainMenuBuilder.windowMenu

        // Registered here, not application(_:open:), per Finicky's approach
        // (docs/research/2026-07-27-link-routing-macos.md section 2) -- and
        // specifically *before* didFinishLaunching, because a cold launch
        // via a link click delivers its kAEGetURL event in the gap between
        // will- and didFinishLaunching. RoutingCoordinator queues the route
        // until markReady() below, since BRWEngine/profiles aren't up yet.
        URLEventHandler.shared.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Both install a global NSEvent monitor in their own init(), which
        // must exist before the user's first relevant keypress -- touching
        // .shared here (rather than only implicitly, e.g. the first time a
        // menu action references ShortcutsOverlayController.shared) forces
        // that to happen at launch instead of lazily on first use, which
        // would otherwise silently miss a bare "?" or Ctrl+Tab pressed
        // before anything else happened to touch either singleton.
        _ = ShortcutsOverlayController.shared
        _ = TabCyclingController.shared

        // History/Bookmarks menus are single global NSMenus (the menu bar
        // isn't per-window) but their dynamic sections are per-profile --
        // refresh them to match whichever window just became key. Registered
        // before any window opens below so the very first window's
        // makeKeyAndOrderFront also triggers the initial population.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let controller = (notification.object as? NSWindow)?.windowController as? BrowserWindowController else { return }
            self.mainMenuBuilder.rebuildRecentHistory(for: controller.profile)
            self.mainMenuBuilder.rebuildBookmarksMenu(for: controller.profile)
        }

        let profilesRootPath = CommandLineArgs.profilesRootPath()
        guard BRWEngine.initialize(withProfilesRootPath: profilesRootPath) else {
            NSLog("Browser: CEF failed to initialize (root_cache_path=%@)", profilesRootPath)
            NSApp.terminate(nil)
            return
        }

        // A route already queued here means this was a cold launch via a
        // routed link (see applicationWillFinishLaunching above) -- in that
        // case markReady() below opens the right profile's window for that
        // link, and opening the usual --profile/--url default window on top
        // of it would just be a spurious extra window.
        let coldLaunchWasRouted = RoutingCoordinator.shared.hasPendingRoutes
        RoutingCoordinator.shared.markReady()

        if !coldLaunchWasRouted {
            let profile = ProfileManager.shared.profileOrCreate(named: CommandLineArgs.profileName())
            WindowManager.shared.openNewWindow(profile: profile, initialURL: CommandLineArgs.initialURL())
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // CEF's required shutdown sequencing (close every browser, wait for
    // OnBeforeClose, only then CefShutdown) happens in -[BRWApplication
    // terminate:], not here -- see that override for why
    // applicationShouldTerminate:/applicationWillTerminate can't do this job
    // for a CEF-backed app.

    /// ⌘N -- new window in the same profile as the key window (falls back to
    /// the default profile if no window is open), per
    /// docs/plans/2026-07-27-browser-plan.md's per-window profile identity.
    @objc func newWindow(_ sender: Any?) {
        let profile = WindowManager.shared.keyBrowserWindowController?.profile
            ?? ProfileManager.shared.profileOrCreate(named: ProfileManager.defaultProfileName)
        WindowManager.shared.openNewWindow(profile: profile)
    }

    @objc func newProfilePrompt(_ sender: Any?) {
        guard let profile = NewProfilePrompt.run() else { return }
        mainMenuBuilder.rebuildProfilesMenu()
        WindowManager.shared.openNewWindow(profile: profile)
    }

    @objc func openProfileWindow(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        WindowManager.shared.openNewWindow(profile: profile)
    }

    /// Shared click handler for the History menu's recent-items section and
    /// the Bookmarks menu's items (see MainMenuBuilder) -- both just carry a
    /// URL string as `representedObject` and want "open in the key window's
    /// active tab as a new tab, or a new window if none is open."
    @objc func openMenuURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        if let controller = WindowManager.shared.keyBrowserWindowController {
            controller.addTab(url: url, makeActive: true)
        } else {
            let profile = ProfileManager.shared.profileOrCreate(named: ProfileManager.defaultProfileName)
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        }
    }

    /// ⌘, -- standard macOS placement. Routing rules, the default-profile
    /// picker, and "Make Default Browser…" all live in this one window (see
    /// SettingsWindowController) rather than as separate menu items.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
