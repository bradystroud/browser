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

    /// CefSettings.root_cache_path -- all profile cache_paths must live under
    /// this shared parent (see AGENTS.md / docs/research).
    static func profilesRootPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let profilesRoot = appSupport.appendingPathComponent("Browser").appendingPathComponent("Profiles")
        try? FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        return profilesRoot.path
    }
}
