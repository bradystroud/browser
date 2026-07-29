import Foundation

/// `UserDefaults.standard` is process-wide and, unlike `session.json`/
/// `profiles.json` (browser-1rp), is not scoped by `--profiles-root` at all
/// -- an agent's "isolated" test launch writing a preference (e.g. Omnibox
/// display mode, Reader font size) through `.standard` would silently change
/// Brady's real settings too, and no agent could verify preference-driven
/// behavior without that risk (browser-xrq). Every preference-backed
/// setting should read/write through `AppPreferencesStore.current` instead
/// of `UserDefaults.standard` directly.
///
/// A normal launch (no `--profiles-root` override) still resolves to
/// `.standard`, exactly as before -- only an explicit override changes
/// anything, redirecting to a suite derived from that same path (see
/// `ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride:)`,
/// the pure/testable half of this logic).
enum AppPreferencesStore {
    static var current: UserDefaults {
        guard let override = ProfilesRootResolver.explicitOverride(arguments: CommandLine.arguments) else {
            return .standard
        }
        let suiteName = ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: override)
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
