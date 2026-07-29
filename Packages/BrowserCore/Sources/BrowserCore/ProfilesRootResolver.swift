import Foundation

/// Pure, dependency-free resolution of where a launch's profile-scoped state
/// should live, given its raw command-line arguments and the machine's
/// Application Support directory path -- factored out of `Sources/App/
/// CommandLineArgs.swift` (browser-1rp) so it's unit-testable via
/// BrowserCore's own `swift test`, the same "one copy of the logic, two ways
/// to build it" pattern this package's other files already use for
/// Sources/App (see CLAUDE.md) -- `Sources/App/CMakeLists.txt` compiles this
/// same file directly into the Browser executable too.
///
/// Exists because of a real bug (browser-1rp): `SessionStore`/
/// `ProfileManager` used to hardcode `<appSupportDirectory>/Browser/
/// {session,profiles}.json` regardless of `--profiles-root`, so an agent's
/// "isolated" test launch actually read and wrote Brady's real session/
/// profile state every time. `sessionAndProfilesMetadataDirectory(_:_:)`
/// below is what those two stores now call instead.
public enum ProfilesRootResolver {
    /// The raw `--profiles-root <path>` value, if the launch explicitly
    /// passed one -- `nil` for a normal launch. Shared by both functions
    /// below so an explicit override always means the same thing regardless
    /// of which one is asked.
    public static func explicitOverride(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--profiles-root"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// CEF's `root_cache_path` (see `CommandLineArgs.profilesRootPath()`'s
    /// own doc comment for why CEF's process-singleton lock makes this the
    /// only way to run a second, fully independent instance). An explicit
    /// override is used exactly as given; the default nests under
    /// `<appSupportDirectory>/Browser/Profiles`.
    public static func profilesRootPath(arguments: [String], appSupportDirectory: String) -> String {
        if let override = explicitOverride(arguments: arguments) {
            return override
        }
        return (appSupportDirectory as NSString).appendingPathComponent("Browser/Profiles")
    }

    /// Where `SessionStore`/`ProfileManager`'s `session.json`/`profiles.json`
    /// live (browser-1rp). An explicit `--profiles-root <path>` override
    /// resolves to that *same* path (a sibling of the per-profile cache
    /// directories `profilesRootPath(arguments:appSupportDirectory:)`
    /// resolves to underneath it) -- fully containing a test instance's
    /// session/profile metadata under the one directory it picked, instead
    /// of silently escaping it into the real Application Support location.
    ///
    /// A normal (unflagged) launch resolves to exactly
    /// `<appSupportDirectory>/Browser` -- deliberately **not** the same
    /// default as `profilesRootPath` above (that one additionally nests
    /// `/Profiles`), so real users' existing `session.json`/`profiles.json`
    /// stay exactly where they've always been; changing the default here
    /// would silently orphan them.
    public static func sessionAndProfilesMetadataDirectory(arguments: [String], appSupportDirectory: String) -> String {
        if let override = explicitOverride(arguments: arguments) {
            return override
        }
        return (appSupportDirectory as NSString).appendingPathComponent("Browser")
    }

    /// A stable, CFPreferences-safe `UserDefaults(suiteName:)` value derived
    /// from an explicit `--profiles-root <path>` override (browser-xrq) --
    /// `UserDefaults.standard` is process-wide and, unlike session.json/
    /// profiles.json above, isn't scoped by `--profiles-root` at all, so an
    /// agent's "isolated" test launch writing a preference (e.g. Omnibox
    /// display mode, Reader font size) through `.standard` would silently
    /// change Brady's real settings too. Deterministic -- not hash-seed-
    /// randomized like Swift's default `String.hashValue` -- so the same
    /// `--profiles-root` path always resolves to the same suite across
    /// separate launches, the same way a given path always resolves to the
    /// same `session.json` above (letting a preference set in one launch
    /// against a scratch directory still read back in a later launch against
    /// that same directory, not just within a single process's lifetime).
    public static func testPreferencesSuiteName(profilesRootOverride: String) -> String {
        let sanitized = String(profilesRootOverride.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        })
        return "dev.stroud.browser.testprefs.\(sanitized)"
    }

    /// One profile's own directory -- root_cache_path/<profile.id> -- keyed
    /// by the profile's immutable UUID, not its mutable display name
    /// (browser-ojw). Everything that used to live at
    /// `<profilesRoot>/<profile name>/...` (CEF's own cache_path contents --
    /// Cookies, History, etc. -- plus this app's own per-profile JSON/SQLite
    /// stores, which all shared that same directory) now lives here instead,
    /// so renaming a profile is purely a metadata change (see
    /// `ProfileManager.updateProfile`) with no directory to move and no
    /// stale-until-reopened identity for an already-open window.
    public static func profileDirectory(profilesRoot: String, profileId: String) -> String {
        (profilesRoot as NSString).appendingPathComponent(profileId)
    }
}
