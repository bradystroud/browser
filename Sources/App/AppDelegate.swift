import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mainMenuBuilder = MainMenuBuilder()

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

    func applicationWillTerminate(_ notification: Notification) {
        BRWEngine.shutdown()
    }

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

    /// ⌘, -- standard macOS placement. Routing rules, the default-profile
    /// picker, and "Make Default Browser…" all live in this one window (see
    /// SettingsWindowController) rather than as separate menu items.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
