import Foundation

/// Persists one profile's BlockingSettings (BlockListCore) as
/// blocking.json inside that profile's own cache directory --
/// root_cache_path/<profile id>/blocking.json (browser-ojw), alongside
/// whatever CEF itself stores there (see Sources/Bridge/BRWEngine.mm's
/// cache_path convention). Unlike ProfileManager/RoutingRulesStore (one
/// shared file for all profiles), this is genuinely per-profile: one small
/// file per profile directory, loaded/saved by id on demand rather than
/// kept as one big in-memory singleton.
///
/// Defaults to enabled with an empty allowlist (BlockingSettings()'s own
/// default) for any profile that's never had its blocking settings
/// touched, per browser-12m.5.1's "default enabled" requirement.
enum BlockingSettingsStore {
    static func load(forProfileId profileId: String) -> BlockingSettings {
        guard let data = try? Data(contentsOf: fileURL(forProfileId: profileId)),
              let decoded = try? JSONDecoder().decode(BlockingSettings.self, from: data) else {
            return BlockingSettings()
        }
        return decoded
    }

    static func save(_ settings: BlockingSettings, forProfileId profileId: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let url = fileURL(forProfileId: profileId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(forProfileId profileId: String) -> URL {
        URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            .appendingPathComponent("blocking.json")
    }
}
