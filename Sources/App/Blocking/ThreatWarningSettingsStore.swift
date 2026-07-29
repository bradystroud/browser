import Foundation

/// Persists one profile's ThreatWarningSettings (BlockListCore) as
/// threat_warning.json inside that profile's own cache directory --
/// root_cache_path/<profile id>/threat_warning.json (browser-ojw), the same
/// per-profile JSON-file pattern as BlockingSettingsStore (see that file's
/// own doc comment) but kept as its own file rather than folded into
/// blocking.json: ad/tracker blocking and the phishing/malware warning are
/// independent list categories with independent treatment (browser-12m.6),
/// and this keeps their persisted settings independent too.
///
/// Defaults to enabled (ThreatWarningSettings()'s own default) for any
/// profile that's never had this setting touched.
enum ThreatWarningSettingsStore {
    static func load(forProfileId profileId: String) -> ThreatWarningSettings {
        guard let data = try? Data(contentsOf: fileURL(forProfileId: profileId)),
              let decoded = try? JSONDecoder().decode(ThreatWarningSettings.self, from: data) else {
            return ThreatWarningSettings()
        }
        return decoded
    }

    static func save(_ settings: ThreatWarningSettings, forProfileId profileId: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let url = fileURL(forProfileId: profileId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(forProfileId profileId: String) -> URL {
        URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            .appendingPathComponent("threat_warning.json")
    }
}
