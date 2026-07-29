import Foundation
import BrowserCore

/// Reads the same "strip tracking params before routing" preference
/// `Sources/App/Routing/LinkHandlingPreferences.swift` does, without
/// depending on that file directly (it lives in the Xcode/CMake app target,
/// not a package `browser-cli` can import). `AppPreferencesStore` (also
/// `Sources/App`) resolves to `.standard` normally, or a
/// `--profiles-root`-scoped suite otherwise, via `BrowserCore`'s
/// `ProfilesRootResolver.testPreferencesSuiteName` -- a real, shared
/// dependency both sides already have, so this is a faithful re-read of the
/// exact same value, not a guess at it. Only the "which suite" question is
/// shared code; the key name and true-by-default fallback are duplicated
/// from that file (both tiny, unlikely-to-drift constants) rather than
/// pulling the whole App target in for one Bool.
///
/// Only stripping is replicated here, not `LinkHandlingPreferences.
/// unshortenLinks` -- un-shortening is a real network round-trip before a
/// link even opens (see that property's own doc comment), which would turn
/// `route-test` from an instant, fully offline command into one with a
/// network dependency and its own failure modes. Left out deliberately; a
/// route-test result never claims to follow shortened links.
enum LinkHandlingPreferencesReader {
    private static let stripTrackingParamsKey = "BrowserStripTrackingParams"

    static func stripTrackingParams(arguments: [String]) -> Bool {
        let defaults: UserDefaults
        if let override = ProfilesRootResolver.explicitOverride(arguments: arguments),
           let suiteDefaults = UserDefaults(suiteName: ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: override)) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
        guard defaults.object(forKey: stripTrackingParamsKey) != nil else { return true }
        return defaults.bool(forKey: stripTrackingParamsKey)
    }
}
