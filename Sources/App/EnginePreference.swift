import Foundation

/// The engine a tab uses when no site rule says otherwise. Global rather
/// than per profile, like the site rules themselves (see EngineRulesStore).
/// Takes effect for the next page a tab opens; tabs already showing a page
/// keep their engine.
enum EnginePreference {
    private static let key = "BrowserEngineChoice"

    /// As chosen in Settings. `CommandLineArgs.defaultEngine()` is what the
    /// app actually uses: an explicit `--engine` launch argument wins over it.
    static var current: EngineChoice {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- so an agent's scratch launch can flip engines without
            // changing which engine Brady's real app uses.
            EngineChoice(rawValue: AppPreferencesStore.current.string(forKey: key) ?? "") ?? .cef
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: key)
        }
    }
}
