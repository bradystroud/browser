import Foundation
import BrowserCore

/// Reads the same "strip tracking params before routing" preference
/// `Sources/App/Routing/LinkHandlingPreferences.swift` does, without
/// depending on that file directly (it lives in the Xcode/CMake app target,
/// not a package `browser-cli` can import). `AppPreferencesStore` (also
/// `Sources/App`) resolves to the app's `.standard` normally -- the
/// `dev.stroud.browser` domain, which this unbundled tool has to name
/// explicitly, since its own `.standard` is a domain of its own -- or a
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
    private static let littleWindowForExternalLinksKey = "BrowserLittleWindowForExternalLinks"

    static func stripTrackingParams(arguments: [String]) -> Bool {
        let defaults = preferences(arguments: arguments)
        guard defaults.object(forKey: stripTrackingParamsKey) != nil else { return true }
        return defaults.bool(forKey: stripTrackingParamsKey)
    }

    /// `LinkHandlingPreferences.littleWindowForExternalLinks`, off by default.
    static func littleWindowForExternalLinks(arguments: [String]) -> Bool {
        preferences(arguments: arguments).bool(forKey: littleWindowForExternalLinksKey)
    }

    /// The app's bundle identifier, whose defaults domain is the app's
    /// `UserDefaults.standard`.
    static let appDefaultsDomain = "dev.stroud.browser"

    static func preferencesSuiteName(arguments: [String]) -> String {
        guard let override = ProfilesRootResolver.explicitOverride(arguments: arguments) else {
            return appDefaultsDomain
        }
        return ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: override)
    }

    private static func preferences(arguments: [String]) -> UserDefaults {
        UserDefaults(suiteName: preferencesSuiteName(arguments: arguments)) ?? .standard
    }
}
