import Foundation

enum CommandLineArgs {
    /// `--profile <name>` launch argument; nil when absent, and the caller
    /// then uses ProfileManager.fallbackProfile. This is the M0
    /// profile-isolation proof: launch two instances with different
    /// `--profile` values and their cookies must not be shared.
    static func profileName() -> String? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--profile"), index + 1 < args.count {
            return args[index + 1]
        }
        return nil
    }

    /// `--url <url>` launch argument override, for testing without UI
    /// automation; defaults to "about:blank" -- Tab's sentinel for "show the
    /// internal start page" (browser-5kq.3), same as ⌘T new tabs, so the
    /// plain-launch default window (no session to restore, no explicit
    /// --url) gets the start page too.
    static func initialURL() -> String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--url"), index + 1 < args.count {
            return args[index + 1]
        }
        return "about:blank"
    }

    /// `--test-no-activate` launch flag for contained, non-interactive quit
    /// testing: WindowManager skips NSApp.activate(ignoringOtherApps:) and
    /// positions new windows off the visible screen frame, so a test process
    /// exercises the same real NSWindow/close paths without ever stealing
    /// keyboard focus or becoming visible on the actual display -- see
    /// docs/ai-tasks/quit-crash-notes.md (a stray real click on a focus-
    /// stolen test window is what this exists to prevent). No-ops (returns
    /// false) unless explicitly passed, so normal launches are unaffected.
    static func testNoActivate() -> Bool {
        CommandLine.arguments.contains("--test-no-activate")
    }

    /// CefSettings.root_cache_path -- all profile cache_paths must live under
    /// this shared parent (see AGENTS.md / docs/research). `--profiles-root
    /// <path>` overrides the default `~/Library/Application Support/Browser/
    /// Profiles` -- CEF's process-singleton lock is scoped to this one
    /// directory (not per-profile), so this is the only way to run a second,
    /// fully independent instance for testing without quitting whichever one
    /// is already running against the default path.
    ///
    /// Path logic itself lives in BrowserCore's `ProfilesRootResolver`
    /// (browser-1rp) -- pure/dependency-free, so it's unit-testable via
    /// `swift test`, unlike this enum itself (Xcode-app-only, no test
    /// target). See that type's own doc comment for why
    /// sessionAndProfilesMetadataDirectory() below is a *separate* function
    /// with its own default, not just a second call to this one.
    static func profilesRootPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        let profilesRoot = ProfilesRootResolver.profilesRootPath(arguments: CommandLine.arguments, appSupportDirectory: appSupport)
        try? FileManager.default.createDirectory(atPath: profilesRoot, withIntermediateDirectories: true)
        return profilesRoot
    }

    /// Where completed downloads are written (browser-5kq.14). A normal
    /// launch resolves to the user's real `~/Downloads`, exactly as before
    /// this existed; an explicit `--profiles-root <path>` launch resolves to
    /// `<path>/Downloads`, so an isolated test launch can exercise the real
    /// download pipeline without dropping files into the actual Downloads
    /// folder. Rule itself lives in BrowserCore's `ProfilesRootResolver`
    /// (unit-tested there); this enum just supplies the machine's home
    /// directory, the same way `profilesRootPath()` supplies Application
    /// Support.
    static func downloadsDirectory() -> String {
        ProfilesRootResolver.downloadsDirectory(
            arguments: CommandLine.arguments, homeDirectory: NSHomeDirectory())
    }

    /// One profile's own directory under `profilesRootPath()`, keyed by its
    /// immutable `id` (browser-ojw) -- the single call every per-profile
    /// store (CEF's own cache_path, BlockingSettingsStore, PermissionStore,
    /// ProfileDataStoreManager, FaviconLoader, etc.) should go through,
    /// rather than each independently rebuilding `profilesRootPath()/<key>`
    /// with its own choice of key. See BrowserCore's
    /// `ProfilesRootResolver.profileDirectory(profilesRoot:profileId:)` for
    /// the pure/tested half of this.
    static func profileDirectory(profileId: String) -> String {
        ProfilesRootResolver.profileDirectory(profilesRoot: profilesRootPath(), profileId: profileId)
    }

    /// Where `SessionStore`/`ProfileManager` read/write `session.json`/
    /// `profiles.json` (browser-1rp: previously hardcoded regardless of
    /// `--profiles-root`, so every "isolated" test launch actually read and
    /// wrote Brady's real session/profile state). A normal launch resolves
    /// to the exact same `~/Library/Application Support/Browser` directory
    /// those two stores have always used; an explicit `--profiles-root
    /// <path>` launch resolves to that same path, fully containing a test
    /// instance's session/profile metadata alongside its per-profile cache
    /// directories under `profilesRootPath()` above -- see
    /// `ProfilesRootResolver.sessionAndProfilesMetadataDirectory`'s own doc
    /// comment for why this can't just reuse profilesRootPath()'s default.
    static func sessionAndProfilesMetadataDirectory() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        let dir = ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments, appSupportDirectory: appSupport)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Which engine to launch with: an explicit `--engine cef|webkit` launch
    /// argument if given (browser-n50), otherwise the Settings preference
    /// (browser-2a7), otherwise cef. Any unrecognized value falls back to
    /// cef, matching this codebase's existing "invalid input is the safe
    /// default" convention (see RuleMatcher/BlockingSettings). See
    /// Engine/WebKitEngineAdapter.swift's `ActiveEngine` for where this
    /// actually picks the conformer.
    ///
    /// The launch argument deliberately wins over the stored preference, so a
    /// test launch can pin an engine without depending on -- or disturbing --
    /// whatever is saved.
    static func engineChoice() -> EngineChoice {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--engine"), index + 1 < args.count else {
            return EnginePreference.current
        }
        switch args[index + 1] {
        case "webkit": return .webkit
        default: return .cef
        }
    }

    /// True when the launch explicitly asked for a particular profile/URL
    /// (`--profile`/`--url`), as opposed to profileName()/initialURL() just
    /// returning their defaults. Used by AppDelegate to decide whether the
    /// usual default window should still open alongside a restored session --
    /// an explicit override is a deliberate ask ("open this"), so it always
    /// gets its own window even when restore already reopened yesterday's
    /// tabs, the same way a routed link launch does.
    static func hasExplicitProfileOrURLOverride() -> Bool {
        let args = CommandLine.arguments
        return args.contains("--profile") || args.contains("--url")
    }

    /// `--show-settings-tab <identifier>` launch argument: opens the
    /// Settings window on a specific tab at launch, with no synthetic
    /// click/keystroke -- the sanctioned way an agent can drive this
    /// window for screenshot verification under AGENTS.md's UI
    /// verification protocol (same "explicit flag, no-op unless passed"
    /// pattern as testNoActivate() above). <identifier> is one of
    /// SettingsWindowController's pane identifiers ("general", "links",
    /// "profiles", "privacy", "start-page", "passwords", "autofill",
    /// "safari", "extensions"), an older name for one ("routing-rules",
    /// "safari-sync"), or "autofill:<section>" ("cards", "addresses",
    /// "emails") -- see SettingsWindowController.showTab(identifier:).
    /// Returns nil (no-op) unless explicitly passed, so normal launches are
    /// unaffected.
    static func showSettingsTabIdentifier() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--show-settings-tab"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
