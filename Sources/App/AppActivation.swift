import AppKit

/// The one place the app brings itself to the front. Every activation goes
/// through here so that `--test-no-activate` is honoured everywhere: an
/// agent's scratch instance that activates takes the owner's keyboard, and
/// whatever he is typing in another app lands in the scratch window.
enum AppActivation {
    static func activate() {
        guard !CommandLineArgs.testNoActivate() else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
