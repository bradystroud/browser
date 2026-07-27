import AppKit

// The active engine's application-integration must become NSApp before
// anything else touches NSApplication.shared -- see
// BrowserEngine.bootstrapApplication and, for the CEF specifics,
// Sources/Bridge/BRWApplication.h.
ActiveEngine.bootstrapApplication()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
