import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let profileName = CommandLineArgs.profileName()
        let profilesRootPath = CommandLineArgs.profilesRootPath()

        guard BRWEngine.initialize(withProfilesRootPath: profilesRootPath) else {
            NSLog("Browser: CEF failed to initialize (root_cache_path=%@)", profilesRootPath)
            NSApp.terminate(nil)
            return
        }

        let controller = BrowserWindowController(profileName: profileName, initialURL: CommandLineArgs.initialURL())
        windowController = controller
        controller.showAndLoadInitialURL()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController = nil
        BRWEngine.shutdown()
    }
}
