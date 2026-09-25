import AppKit

// The active engine's application-integration must become NSApp before
// anything else touches NSApplication.shared -- see
// BrowserEngine.bootstrapApplication and, for the CEF specifics,
// Sources/Bridge/BRWApplication.h.
ActiveEngine.bootstrapApplication()

// AppKit's own window restoration is off: the app restores its session
// itself (SessionStore / session.json). Left on, AppKit keeps a crash
// history per bundle id -- shared by the installed app, dev builds and
// every scratch instance -- and after a few non-clean exits it blocks
// launch on a modal "reopen windows?" alert before
// applicationDidFinishLaunching runs, so the engine and the CLI socket
// never start. Registration-domain defaults live only in memory.
UserDefaults.standard.register(defaults: [
    "ApplePersistenceIgnoreState": true,
    "NSQuitAlwaysKeepsWindows": false,
])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
