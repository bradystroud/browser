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
        windowControllers.append(controller)
        controller.onWindowClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
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
        controller.show()
        return controller
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
        for controller in windowControllers {
            controller.window?.close()
        }
    }
}
