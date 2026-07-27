import AppKit

// BRWApplication must become NSApp before anything else touches
// NSApplication.shared -- see Sources/Bridge/BRWApplication.h.
BRWApplication.bootstrap()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
