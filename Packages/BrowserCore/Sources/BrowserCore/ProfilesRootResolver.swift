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
    /// The `--profiles-root <path>` value, canonicalized, if the launch
    /// explicitly passed one -- `nil` for a normal launch. Shared by every
    /// function below so an explicit override always means the same
    /// directory regardless of which one is asked.
    ///
    /// Canonicalized here, once, rather than left as whatever string form
    /// the caller happened to type (browser-x4l): CEF's own `cache_path`
    /// validation rejects a mismatch between a symlinked form (e.g. macOS's
    /// permanent `/tmp` -> `/private/tmp` symlink) and the canonical form it
    /// resolves internally, silently falling back to in-memory-only storage
    /// for the whole profile -- and separately, `CLISocketPath`'s hash is
    /// computed over this same directory string, so the app and the
    /// `browser` CLI must agree on one canonical form or they hash to
    /// different socket paths for what's really the same instance.
    public static func explicitOverride(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--profiles-root"), index + 1 < arguments.count else {
            return nil
        }
        return canonicalize(arguments[index + 1])
    }

    /// Resolves `path` to its real, symlink-free absolute form. Deliberately
    /// NOT `NSString`/`URL`'s own `resolvingSymlinksInPath()`: Apple's
    /// implementation intentionally leaves macOS's `/tmp`, `/etc`, `/var`
    /// compatibility symlinks (-> `/private/tmp` etc.) unresolved, for
    /// application-compatibility reasons that don't apply here -- and `/tmp`
    /// is exactly the mismatch browser-x4l needs fixed (a very natural
    /// scratch-directory prefix for an agent's test launch). Finds the
    /// longest prefix of `path` that actually exists on disk, resolves
    /// *that* with the real POSIX `realpath(3)` (which does fully resolve
    /// `/tmp`), and appends whatever doesn't exist yet -- typically the
    /// scratch directory itself, not created until the app/CLI actually
    /// needs it -- unchanged.
    private static func canonicalize(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        var existingCount = components.count
        while existingCount > 0 {
            let prefix = NSString.path(withComponents: Array(components.prefix(existingCount)))
            if FileManager.default.fileExists(atPath: prefix) {
                break
            }
            existingCount -= 1
        }
        guard existingCount > 0 else { return URL(fileURLWithPath: path).path }

        let existingPrefix = NSString.path(withComponents: Array(components.prefix(existingCount)))
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(existingPrefix, &buffer) != nil else { return URL(fileURLWithPath: path).path }
        let resolvedPrefix = String(cString: buffer)

        let remainder = components.suffix(from: existingCount)
        return remainder.reduce(resolvedPrefix) { ($0 as NSString).appendingPathComponent($1) }
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

    /// Where a completed download's file is written (browser-5kq.14). A
    /// normal launch resolves to the user's real `~/Downloads`, exactly where
    /// downloads have always gone; an explicit `--profiles-root <path>`
    /// launch resolves to `<override>/Downloads` instead.
    ///
    /// Same reasoning as `sessionAndProfilesMetadataDirectory` above, applied
    /// to the one remaining piece of state that still escaped an "isolated"
    /// launch: before this, every agent test that exercised a download wrote
    /// a real file into Brady's actual Downloads folder, and there was no way
    /// to test the download path at all without doing so. `--profiles-root`
    /// already means "contain this launch's state under one directory", and a
    /// downloaded file is that launch's state.
    public static func downloadsDirectory(arguments: [String], homeDirectory: String) -> String {
        if let override = explicitOverride(arguments: arguments) {
            return (override as NSString).appendingPathComponent("Downloads")
        }
        return (homeDirectory as NSString).appendingPathComponent("Downloads")
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
