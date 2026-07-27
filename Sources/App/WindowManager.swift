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
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    var keyBrowserWindowController: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windowControllers.last
    }
}
