import AppKit
import VisionKit

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
        // until markReady() below, since the engine/profiles aren't up yet.
        URLEventHandler.shared.register()

        // Explicit kAEQuitApplication handler -- Dock "Quit", "quit" via
        // AppleScript/osascript, and logout/restart/shutdown all deliver this
        // Apple Event rather than a direct -terminate: message send (unlike
        // Cmd+Q and the app's own Quit menu item, which dispatch straight to
        // -[NSApplication terminate:] via the menu's key-equivalent/action).
        // NSApplication has its own private, undocumented bridge from this
        // event to -terminate: -- registering our own handler here (same
        // pattern as URLEventHandler's kAEGetURL, just above) replaces that
        // bridge with something we control and can debug, rather than relying
        // on framework-internal wiring that isn't documented.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        NSApp.terminate(nil)
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
        // Same reason: its whole job is to observe TabLifecycleCenter and
        // apply a site's stored settings as each page loads (browser-06d).
        // Instantiated lazily, it would only start observing once the
        // sheet had been opened, so a setting saved in an earlier session
        // wouldn't apply until you opened the sheet again.
        _ = SiteSettingsEnforcer.shared

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
            self.mainMenuBuilder.rebuildRecentlyClosed(for: controller.profile)
            self.mainMenuBuilder.rebuildBookmarksMenu(for: controller.profile)
        }

        // BookmarkStore itself has no notion of "the active window" (it's a
        // per-profile store, not UI), so a bookmark change refreshes the menu
        // here using whichever profile is currently key -- covers the case a
        // bookmark is added/moved/deleted without a BrowserWindowController
        // regaining key status right after (e.g. from the Bookmarks manager
        // window while it stays frontmost). If no BrowserWindowController is
        // key at the moment of the change, the didBecomeKey observer above
        // still catches it the next time one is.
        NotificationCenter.default.addObserver(
            forName: .bookmarkStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let controller = NSApp.keyWindow?.windowController as? BrowserWindowController else { return }
            self.mainMenuBuilder.rebuildBookmarksMenu(for: controller.profile)
        }

        let profilesRootPath = CommandLineArgs.profilesRootPath()
        // Before initialize(), so no browser can ever exist with the engine
        // still pointed at the default ~/Downloads (browser-5kq.14).
        ActiveEngine.setDownloadDirectory(CommandLineArgs.downloadsDirectory())
        guard ActiveEngine.initialize(profilesRootPath: profilesRootPath) else {
            NSLog("Browser: engine failed to initialize (root_cache_path=%@)", profilesRootPath)
            NSApp.terminate(nil)
            return
        }
        // Must start only once the engine is up: the very first snapshot
        // push (loading the starter list + every existing profile's
        // BlockingSettings) needs ProfileManager and the engine ready, and
        // every tab created from here on needs a snapshot already published
        // before its first request -- see ContentBlockerCoordinator's doc
        // comment (browser-12m.5.1).
        ContentBlockerCoordinator.shared.start()
        // Same requirement, independent feature (browser-12m.6) -- see
        // ThreatListCoordinator's doc comment.
        ThreatListCoordinator.shared.start()
        // browser-7jz.3 -- registers with PageMessageDispatcher and
        // UNUserNotificationCenter before any tab can navigate.
        WebPushCoordinator.shared.activate()
        // browser-5kq.2 -- a Mac hardware/OS capability check, done once
        // here rather than per tab because the engine keeps it as one
        // process-wide flag; see BrowserEngine.setVisualLookUpAvailable(_:).
        // VisionKit's ImageAnalyzer needs macOS 13+ -- this app's deployment
        // target is 12.0, so on an older Mac the flag is never set to true
        // and no "Look Up Image" menu item ever appears.
        if #available(macOS 13.0, *) {
            ActiveEngine.setVisualLookUpAvailable(ImageAnalyzer.isSupported)
        }

        // See -[BRWApplication terminate:] and WindowManager.closeAllWindowsForShutdown:
        // quitting must close every Swift-owned window (and thus its tabs'
        // engine tabs) through their normal path before the engine's own
        // shutdown runs, not leave them for AppKit's own at-exit teardown to
        // reach afterward.
        ActiveEngine.setWindowCloseHandler {
            WindowManager.shared.closeAllWindowsForShutdown()
        }

        // A route already queued here means this was a cold launch via a
        // routed link (see applicationWillFinishLaunching above) -- in that
        // case markReady() below opens the right profile's window for that
        // link, regardless of session restore (see below) -- a routed link
        // click always means "open this," restored or not.
        let coldLaunchWasRouted = RoutingCoordinator.shared.hasPendingRoutes
        RoutingCoordinator.shared.markReady()
        CLIServer.shared.start() // browser-82d: the `browser` CLI's control socket -- see CLI/CLIServer.swift.

        // Holding Shift at launch skips restore entirely -- the standard
        // "hold a modifier to skip the usual startup behavior" convention
        // (same mechanism macOS itself uses for login items). Checked here,
        // early in the launch sequence, while the key is still very likely
        // held from whatever launched the app moments ago.
        let skipRestore = NSEvent.modifierFlags.contains(.shift)
        let restoredAnyWindow = !skipRestore && WindowManager.shared.restoreSession()

        // An explicit --profile/--url override always still opens its own
        // window, restored session or not (see CommandLineArgs.
        // hasExplicitProfileOrURLOverride's doc comment) -- only a plain
        // launch (no override, no route) skips the usual default window
        // when restore already provided one.
        if coldLaunchWasRouted || !restoredAnyWindow || CommandLineArgs.hasExplicitProfileOrURLOverride() {
            if !coldLaunchWasRouted {
                let profile = ProfileManager.shared.profileOrCreate(named: CommandLineArgs.profileName())
                WindowManager.shared.openNewWindow(profile: profile, initialURL: CommandLineArgs.initialURL())
            }
        }

        if let tabIdentifier = CommandLineArgs.showSettingsTabIdentifier() {
            SettingsWindowController.shared.showTab(identifier: tabIdentifier)
        }
        DevToolsLaunchOption.applyIfRequested()

        // Last in the launch sequence deliberately (browser-wc7): Sparkle's
        // first scheduled check can put UI on screen, and it should never do
        // that ahead of the window this launch was actually asked for. It
        // no-ops on scratch/dev launches -- see UpdateCoordinator.start().
        UpdateCoordinator.shared.start()
    }

    // Normally true (closing the last window quits, standard for this kind
    // of app) -- except while -[BRWApplication terminate:] is already mid-
    // sequence (ActiveEngine.isTerminating), since then it's the one
    // closing every window as a step in its own close-and-wait-for-CEF
    // sequence, and there's no need for AppKit to also re-enter -terminate:
    // from here (that reentrant call is harmless -- see -terminate:'s guard
    // -- but redundant).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ActiveEngine.isTerminating
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

    /// ⇧⌘N -- Private Browsing (browser-12m.1). Always a fresh, dedicated
    /// ephemeral window/profile -- unlike newWindow(_:) above, there's no
    /// "same profile as the key window" concept here, since a private window
    /// never has a real profile identity at all.
    @objc func newPrivateWindow(_ sender: Any?) {
        WindowManager.shared.openNewPrivateWindow()
    }

    /// View > Enter Picture in Picture (browser-7jz.1) -- see
    /// PictureInPictureScript's own doc comment for why this is a plain
    /// fire-and-forget executeJavaScript(_:) call, not routed through
    /// PageMessageDispatcher.
    @objc func togglePictureInPicture(_ sender: Any?) {
        WindowManager.shared.keyBrowserWindowController?.activeTab?.executeJavaScript(PictureInPictureScript.toggleSource)
    }

    /// View > Responsive Design Mode > <device> -- overrides the key
    /// window's active tab viewport via CDP (browser-6hi.2); see
    /// BRWBrowser.h's -setResponsiveDesignModeWithWidth:... for why this
    /// works without opening DevTools' own UI at all. `sender`'s
    /// representedObject is the ResponsiveDevicePreset the menu item was
    /// built for (see MainMenuBuilder.responsiveDesignModeMenu()).
    @objc func setResponsiveDesignMode(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? ResponsiveDevicePreset,
              let tab = WindowManager.shared.keyBrowserWindowController?.activeTab else { return }
        tab.setResponsiveDesignMode(width: preset.width, height: preset.height, deviceScaleFactor: preset.deviceScaleFactor, mobile: preset.mobile)
    }

    /// View > Responsive Design Mode > Off.
    @objc func clearResponsiveDesignMode(_ sender: Any?) {
        WindowManager.shared.keyBrowserWindowController?.activeTab?.clearResponsiveDesignMode()
    }

    @objc func newProfilePrompt(_ sender: Any?) {
        guard let profile = NewProfilePrompt.run() else { return }
        mainMenuBuilder.rebuildProfilesMenu()
        WindowManager.shared.openNewWindow(profile: profile)
    }

    /// ⌃⌘N -- Profiles > Switch Profile… (browser-sdj.2). The panel is
    /// anchored on whichever browser window is key, and also reads that
    /// window's profile to decide where its selection starts.
    @objc func showProfileSwitcher(_ sender: Any?) {
        ProfileSwitcherController.shared.toggle(relativeTo: WindowManager.shared.keyBrowserWindowController?.window)
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
