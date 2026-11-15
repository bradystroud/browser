import Foundation

/// Settings > Extensions > "Run extensions in Chromium tabs": whether the
/// install list also runs in Chromium tabs, beside WebKit tabs. On unless
/// turned off. Chromium reads its extensions only when it starts, so the
/// engine gets the value of this launch once, before it starts
/// (`isOnThisLaunch`), and a change applies after a relaunch.
enum ChromiumTabExtensionsPreference {
    private static let key = "ExtensionsRunInChromiumTabs"

    static var isOn: Bool {
        get {
            let defaults = AppPreferencesStore.current
            guard defaults.object(forKey: key) != nil else { return true }
            return defaults.bool(forKey: key)
        }
        set { AppPreferencesStore.current.set(newValue, forKey: key) }
    }

    /// The value the engine started with. Read first before the engine
    /// starts, so it never changes during the session.
    static let isOnThisLaunch: Bool = isOn

    /// The setting differs from what this session runs.
    static var needsRelaunch: Bool { isOn != isOnThisLaunch }
}
