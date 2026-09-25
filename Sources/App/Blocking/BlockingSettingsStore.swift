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
        file(forProfileId: profileId).load(default: BlockingSettings())
    }

    static func save(_ settings: BlockingSettings, forProfileId profileId: String) {
        file(forProfileId: profileId).save(settings)
    }

    private static func file(forProfileId profileId: String) -> JSONFile<BlockingSettings> {
        JSONFile(url: URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            .appendingPathComponent("blocking.json"))
    }
}
