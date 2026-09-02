import AppKit

/// Tracks every open BrowserWindowController so ⌘N and the Profiles menu can
/// open a new window against any profile's CefRequestContext (see BRWEngine),
/// regardless of which window is currently key.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var windowControllers: [BrowserWindowController] = []

    private init() {}

    /// `initialURL` defaults to whatever the user's "New windows open with"
    /// setting resolves to right now (browser-m0x). A default argument is
    /// evaluated per call, not once, so a setting changed mid-session takes
    /// effect on the very next ⌘N without anything having to observe it.
    ///
    /// Every caller that already knows which URL it wants -- a routed link, a
    /// bookmark, `browser window new` -- passes one and is unaffected. The
    /// callers that rely on this default are exactly the "just give me a
    /// window" ones: ⌘N, the Profiles menu, and the profile switcher.
    @discardableResult
    func openNewWindow(
        profile: Profile,
        initialURL: String = HomepagePreference.newWindowURL,
        isPrivate: Bool = false
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(profile: profile, initialURL: initialURL, isPrivate: isPrivate)
        registerAndShow(controller)
        return controller
    }

    /// ⇧⌘N (browser-12m.1). `profile` is a fresh, throwaway value with its
    /// own random `id` -- constructed here, never passed to
    /// ProfileManager.shared.addProfile/saved anywhere, purely so
    /// BrowserWindowController (which requires a real `Profile`) has
    /// something to read `.name`/`.colorHex` from. Its `id` still needs to be
    /// unique per window (not, say, a single shared constant) so
    /// frontmostWindowController(forProfileId:)/closeAllWindows(forProfileId:)
    /// -- both keyed by profile id -- can't accidentally conflate two
    /// simultaneously open private windows, or a private window with a real
    /// profile, as the same target.
    @discardableResult
    func openNewPrivateWindow() -> BrowserWindowController {
        let profile = Profile(id: "private-\(UUID().uuidString)", name: "Private", colorHex: "#3a3a3c")
        // Always the start page, never the homepage (browser-m0x): a private
        // window that opened your homepage would hand the one site you visit
        // most a fresh, empty-cookie-jar session every ⇧⌘N, which is the
        // opposite of what reaching for a private window means.
        return openNewWindow(profile: profile, initialURL: HomepagePreference.startPageURL, isPrivate: true)
    }

    /// Shared by openNewWindow and restoreSession: registers the controller,
    /// wires its close callback (dropping it from windowControllers and
    /// scheduling a session save so the persisted session reflects the
    /// closed window), activates the app, and shows it.
    /// Reopens a window closed earlier in this session, or in a previous one
    /// (browser-n2j). Goes through the same registerAndShow(restoring:) path
    /// session restore uses, so a reopened window and a restored window are
    /// built identically -- there is no second way to turn a saved window back
    /// into a live one.
    @discardableResult
    func reopenClosedWindow(
        profile: Profile,
        tabs: [SessionSnapshot.Tab],
        groups: [SessionSnapshot.Group],
        activeIndex: Int
    ) -> BrowserWindowController {
        let controller = BrowserWindowController(profile: profile, initialURL: "about:blank")
        registerAndShow(controller, restoring: tabs, groups: groups, activeIndex: activeIndex)
        return controller
    }

    private func registerAndShow(
        _ controller: BrowserWindowController,
        restoring tabs: [SessionSnapshot.Tab] = [],
        groups: [SessionSnapshot.Group] = [],
        activeIndex: Int = 0
    ) {
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
        controller.show(restoring: tabs, groups: groups, activeIndex: activeIndex)
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
    /// True while closeAllWindowsForShutdown is tearing every window down, so
    /// the recently-closed stack can refuse those closes (browser-n2j).
    ///
    /// Quitting closes every window through the same path a deliberate close
    /// uses. Without this, quitting with six windows open records six
    /// "recently closed" entries -- and the first ⇧⌘T after relaunch reopens a
    /// window session restore has *already* put back, burying the tab the user
    /// actually wanted six presses down. Never reset: the process is ending.
    private(set) var isShuttingDown = false

    func closeAllWindowsForShutdown() {
        // Snapshot the still-fully-open state first -- closing each window
        // below tears down its tabs, and we want to persist what the user
        // actually had open, not whatever's left mid-teardown.
        saveSessionNow()
        isShuttingDown = true
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
            // Private Browsing (browser-12m.1): never persisted, so there's
            // nothing to restore on next launch either -- consistent with
            // "closing a private window discards everything."
            guard !controller.isPrivate else { return nil }
            let tabs = controller.tabs.map {
                SessionSnapshot.Tab(url: $0.urlString, title: $0.title, isPinned: $0.isPinned, groupId: $0.groupId)
            }
            guard !tabs.isEmpty, let frame = controller.window?.frame else { return nil }
            let groups = controller.tabGroups.map {
                SessionSnapshot.Group(id: $0.id, name: $0.name, colorHex: $0.colorHex, isCollapsed: $0.isCollapsed)
            }
            return SessionSnapshot.Window(
                profileId: controller.profile.id,
                frame: SessionSnapshot.WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                tabs: tabs,
                activeTabIndex: controller.activeTabIndex ?? 0,
                groups: groups
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

    /// A saved frame is only meaningful on the display arrangement it was
    /// saved under. Restore it verbatim and a window last closed on a
    /// now-disconnected external display -- or one saved by an agent's own
    /// `--test-no-activate` launch, which parks windows at (-3000, -3000) --
    /// comes back somewhere the user cannot reach, with no way to drag it
    /// on screen. `NSWindow.setFrame` does not constrain to a screen, so
    /// this does: keep the size, and re-centre on the main screen whenever
    /// the saved rectangle does not meaningfully overlap any screen that
    /// actually exists right now.
    static func frameOnAVisibleScreen(_ frame: CGRect) -> CGRect {
        // Enough of the title bar to grab. A window peeking one pixel onto
        // a screen is not recoverable in practice, so partial overlap is
        // not on its own good enough.
        let minimumVisible = CGSize(width: 120, height: 40)
        let isReachable = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= minimumVisible.width && overlap.height >= minimumVisible.height
        }
        guard !isReachable, let screen = NSScreen.main ?? NSScreen.screens.first else { return frame }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width, height: size.height
        )
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
            if let frame = windowSnapshot.frame, let window = controller.window {
                window.setFrame(
                    Self.frameOnAVisibleScreen(
                        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)),
                    display: false)
            }
            registerAndShow(controller, restoring: tabs, groups: windowSnapshot.groups ?? [], activeIndex: windowSnapshot.activeTabIndex)
            restoredAny = true
        }
        return restoredAny
    }
}
