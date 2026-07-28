import Foundation

enum CommandLineArgs {
    /// `--profile <name>` launch argument; defaults to "default". This is the
    /// M0 profile-isolation proof: launch two instances with different
    /// `--profile` values and their cookies must not be shared.
    static func profileName() -> String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--profile"), index + 1 < args.count {
            return args[index + 1]
        }
        return "default"
    }

    /// `--url <url>` launch argument override, for testing without UI
    /// automation; defaults to "https://example.com".
    static func initialURL() -> String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--url"), index + 1 < args.count {
            return args[index + 1]
        }
        return "https://example.com"
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
    static func profilesRootPath() -> String {
        let args = CommandLine.arguments
        let profilesRoot: URL
        if let index = args.firstIndex(of: "--profiles-root"), index + 1 < args.count {
            profilesRoot = URL(fileURLWithPath: args[index + 1])
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            profilesRoot = appSupport.appendingPathComponent("Browser").appendingPathComponent("Profiles")
        }
        try? FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        return profilesRoot.path
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
}
