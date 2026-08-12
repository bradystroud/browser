import Foundation

/// Which rendering engine the app starts with (browser-2a7) -- persisted
/// globally, not per-profile, because it is a property of the *process*: CEF
/// has to install its own `NSApplication` subclass before anything touches
/// `NSApplication.shared` (see `BrowserEngine.bootstrapApplication` and
/// `BRWApplication.h`), so the choice is made on the first line of
/// `main.swift`, long before any profile is known.
///
/// That same constraint is why this only takes effect on restart, and why
/// there is no notification here for anything to observe -- unlike every
/// other preference in this app, nothing can respond to a change at runtime.
/// The Settings pane says so plainly rather than implying a live switch.
enum EnginePreference {
    private static let key = "BrowserEngineChoice"

    /// The engine to launch with, as chosen in Settings. An explicit
    /// `--engine` launch argument overrides it -- see
    /// `CommandLineArgs.engineChoice()`, which is what actually resolves the
    /// two against each other.
    static var current: EngineChoice {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- so an agent's scratch launch can flip engines without
            // changing which engine Brady's real app starts with.
            switch AppPreferencesStore.current.string(forKey: key) {
            case "webkit": return .webkit
            default: return .cef
            }
        }
        set {
            AppPreferencesStore.current.set(newValue == .webkit ? "webkit" : "cef", forKey: key)
        }
    }
}
