import AppKit

/// Tracks every open BrowserWindowController so ⌘N and the Profiles menu can
/// open a new window against any profile's CefRequestContext (see BRWEngine),
/// regardless of which window is currently key.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var windowControllers: [BrowserWindowController] = []

    private init() {}

    @discardableResult
    func openNewWindow(profile: Profile, initialURL: String = "https://example.com") -> BrowserWindowController {
        let controller = BrowserWindowController(profile: profile, initialURL: initialURL)
        registerAndShow(controller)
        return controller
    }

    /// Shared by openNewWindow and restoreSession: registers the controller,
    /// wires its close callback (dropping it from windowControllers and
    /// scheduling a session save so the persisted session reflects the
    /// closed window), activates the app, and shows it.
    private func registerAndShow(_ controller: BrowserWindowController, restoring tabs: [SessionSnapshot.Tab] = [], activeIndex: Int = 0) {
        windowControllers.append(controller)
        controller.onWindowClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
            self.scheduleSessionSave()
        }
        // Activate the app *before* showing the window and focusing its
        // omnibox (see BrowserWindowController.addTab): if the process isn't
        // yet the active application (e.g. launched by directly exec'ing the
        // binary rather than via Launch Services), a first-responder change
        // made before activation completes doesn't reliably stick once
        // activation catches up -- confirmed by reproducing a fresh window's
        // omnibox failing to end up focused/selected with this ordering
        // reversed.
        //
        // Skipped under --test-no-activate: activating steals real keyboard
        // focus on the actual display, which is exactly what that flag exists
        // to avoid for contained test launches -- see CommandLineArgs.
        if !CommandLineArgs.testNoActivate() {
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.show(restoring: tabs, activeIndex: activeIndex)
    }

    var keyBrowserWindowController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windowControllers.last
    }

    /// The frontmost open window belonging to `profileId`, if any -- used by
    /// RoutingCoordinator to decide "open a new tab in an existing window"
    /// vs. "open a new window" for a routed link. Frontmost is approximated
    /// by NSApp.orderedWindows (front-to-back z-order) rather than key/main
    /// status, since the routed link's target profile is very often not the
    /// currently-key window's profile.
    func frontmostWindowController(forProfileId profileId: String) -> BrowserWindowController? {
        for window in NSApp.orderedWindows {
            if let controller = window.windowController as? BrowserWindowController,
               controller.profile.id == profileId,
               windowControllers.contains(where: { $0 === controller }) {
                return controller
            }
        }
        return nil
    }

    /// Closes every open window for `profileId` -- used before deleting a
    /// profile, so CEF isn't left holding a browser against a cache
    /// directory that's about to be removed. Iterates a snapshot of
    /// `windowControllers` (Swift arrays are value types, so mutating the
    /// real property via each window's close-completion callback mid-loop
    /// is safe and doesn't affect this iteration).
    func closeAllWindows(forProfileId profileId: String) {
        for controller in windowControllers where controller.profile.id == profileId {
            controller.window?.close()
        }
    }

    /// Registered with BRWEngine (see AppDelegate.applicationDidFinishLaunching)
    /// as the block +[BRWEngine requestShutdownWithCompletion:] runs before it
    /// touches CEF directly. Closing every window the normal way -- rather
    /// than leaving them alive for CefShutdown+exit(0) to race against --
    /// runs each BrowserWindowController's ordinary windowWillClose, which
    /// closes every tab's BRWBrowser and releases the Tab/controller objects
    /// synchronously, before AppKit's own at-exit window teardown would
    /// otherwise get to them *after* CEF's global state is already torn down
    /// (the EXC_BAD_ACCESS this fixes: see docs/ai-tasks/quit-crash-notes.md).
    /// -[NSWindow close] completing -- not merely CloseBrowser() being called
    /// -- is also what triggers CEF's own OnBeforeClose delivery for a
    /// windowed-rendering browser (see BRWClientHandler::DoClose's comment),
    /// so this is required for CEF's own sake too, not just to avoid the UAF.
    func closeAllWindowsForShutdown() {
        // Snapshot the still-fully-open state first -- closing each window
        // below tears down its tabs, and we want to persist what the user
        // actually had open, not whatever's left mid-teardown.
        saveSessionNow()
        for controller in windowControllers {
            controller.window?.close()
        }
    }

    // MARK: - Session persistence (see SessionStore, docs/ai-tasks/session-restore-notes.md)

    /// The current state of every open window, in SessionSnapshot form.
    /// Windows with zero tabs (shouldn't normally happen -- see
    /// BrowserWindowController.closeTab, which closes the window once its
    /// last tab closes) are skipped defensively rather than persisted as an
    /// empty, unrestorable entry.
    private func currentSnapshot() -> SessionSnapshot {
        let windows: [SessionSnapshot.Window] = windowControllers.compactMap { controller in
            let tabs = controller.tabs.map { SessionSnapshot.Tab(url: $0.urlString, title: $0.title) }
            guard !tabs.isEmpty, let frame = controller.window?.frame else { return nil }
            return SessionSnapshot.Window(
                profileId: controller.profile.id,
                frame: SessionSnapshot.WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                tabs: tabs,
                activeTabIndex: controller.activeTabIndex ?? 0
            )
        }
        return SessionSnapshot(windows: windows)
    }

    /// Debounced -- called on every meaningful per-window change (tab open/
    /// close/navigate, window move/resize) via BrowserWindowController, and
    /// on window close via registerAndShow's onWindowClosed above. See
    /// SessionStore.scheduleSave.
    func scheduleSessionSave() {
        SessionStore.shared.scheduleSave { [weak self] in self?.currentSnapshot() ?? SessionSnapshot(windows: []) }
    }

    /// Immediate -- only called from closeAllWindowsForShutdown, where
    /// there's no time to wait out scheduleSessionSave's debounce.
    private func saveSessionNow() {
        SessionStore.shared.saveNow(currentSnapshot())
    }

    /// Recreates every window/tab from the last persisted session, if any --
    /// called once at launch (see AppDelegate.applicationDidFinishLaunching),
    /// never while the app is already running. Returns whether anything was
    /// actually restored, so the caller knows whether to still open its
    /// normal launch-arg-driven default window.
    ///
    /// A window whose profile no longer exists (deleted since the session
    /// was saved) is skipped entirely -- there's nothing sensible to restore
    /// it as. Each window's tab list is capped at
    /// SessionSnapshot.maxTabsPerWindow (truncating extras) as a sanity
    /// limit against a runaway/stale snapshot.
    @discardableResult
    func restoreSession() -> Bool {
        guard let snapshot = SessionStore.shared.load(), !snapshot.windows.isEmpty else { return false }

        var restoredAny = false
        for windowSnapshot in snapshot.windows {
            guard let profile = ProfileManager.shared.profile(id: windowSnapshot.profileId) else { continue }
            let tabs = Array(windowSnapshot.tabs.prefix(SessionSnapshot.maxTabsPerWindow))
            guard !tabs.isEmpty else { continue }

            let controller = BrowserWindowController(profile: profile, initialURL: "about:blank")
            if let frame = windowSnapshot.frame {
                controller.window?.setFrame(
                    CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            }
            registerAndShow(controller, restoring: tabs, activeIndex: windowSnapshot.activeTabIndex)
            restoredAny = true
        }
        return restoredAny
    }
}
