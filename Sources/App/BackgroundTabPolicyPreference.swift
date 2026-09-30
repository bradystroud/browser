import Foundation

/// How aggressively hidden tabs give up memory -- the slider in Settings >
/// General. Global, not per-profile, and pushed to the engine with
/// ActiveEngine.setBackgroundTabPolicy at launch and on every change.
enum BackgroundTabPolicyPreference {
    private static let key = "BrowserBackgroundTabPolicy"

    /// Defaults to balanced, not WebKit's own "suspend": suspended tabs were
    /// reloading too often when switched back to.
    static var current: BackgroundTabPolicy {
        get {
            guard let raw = AppPreferencesStore.current.string(forKey: key),
                  let policy = BackgroundTabPolicy(rawValue: raw) else { return .balanced }
            return policy
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: key)
            ActiveEngine.setBackgroundTabPolicy(newValue)
            TabMemoryDiagnostics.shared.policyChanged(to: newValue)
        }
    }
}
