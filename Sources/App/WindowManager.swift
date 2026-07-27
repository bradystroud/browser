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
        NSApp.activate(ignoringOtherApps: true)
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
}
