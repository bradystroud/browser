import Foundation

extension Notification.Name {
    /// Posted whenever TabSleepPreferences changes, so TabSleepCoordinator
    /// re-times its sweep without waiting for the old interval to elapse.
    static let tabSleepPreferencesDidChange = Notification.Name("TabSleepPreferencesDidChange")
}

/// Whether background tabs go to sleep on their own, and after how long.
/// Global rather than per profile: it is about this Mac's memory, not about
/// any one set of sites.
enum TabSleepPreferences {
    private static let enabledKey = "BrowserTabSleepEnabled"
    private static let idleSecondsKey = "BrowserTabSleepIdleSeconds"
    private static let awakeTabLimitKey = "BrowserTabSleepAwakeTabLimit"

    static let defaultAwakeTabLimit = 20

    /// The shortest interval a stored value is taken at. Anything shorter
    /// would put a tab to sleep while the user is still flicking between tabs.
    static let minimumIdleInterval: TimeInterval = 10

    static var isEnabled: Bool {
        get { AppPreferencesStore.current.object(forKey: enabledKey) as? Bool ?? true }
        set {
            AppPreferencesStore.current.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .tabSleepPreferencesDidChange, object: nil)
        }
    }

    static var idleInterval: TimeInterval {
        get {
            let stored = AppPreferencesStore.current.double(forKey: idleSecondsKey)
            return stored > 0 ? max(stored, minimumIdleInterval) : TabSleepPolicy.defaultIdleInterval
        }
        set {
            AppPreferencesStore.current.set(max(newValue, minimumIdleInterval), forKey: idleSecondsKey)
            NotificationCenter.default.post(name: .tabSleepPreferencesDidChange, object: nil)
        }
    }

    /// Idle tabs sleep only while more than this many tabs are awake; nil
    /// means idle tabs always sleep. Stored as 0 for nil, so a missing key
    /// can still mean the default.
    static var awakeTabLimit: Int? {
        get {
            guard let stored = AppPreferencesStore.current.object(forKey: awakeTabLimitKey) as? Int else {
                return defaultAwakeTabLimit
            }
            return stored > 0 ? stored : nil
        }
        set {
            AppPreferencesStore.current.set(max(newValue ?? 0, 0), forKey: awakeTabLimitKey)
            NotificationCenter.default.post(name: .tabSleepPreferencesDidChange, object: nil)
        }
    }
}
