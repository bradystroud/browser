import Foundation

/// Per-profile start-page customization: background color (rendered as a
/// simple two-tone gradient from this color -- see StartPageRenderer) and
/// which sections show. Codable, persisted as startpage.json inside that
/// profile's own cache directory, mirroring BlockingSettingsStore's exact
/// pattern (root_cache_path/<profile name>/startpage.json).
struct StartPageSettings: Codable, Equatable {
    var backgroundColorHex: String
    var showFavorites: Bool
    var showFrequentlyVisited: Bool

    init(
        backgroundColorHex: String = ProfileColorPalette.hexValues[7],
        showFavorites: Bool = true,
        showFrequentlyVisited: Bool = true
    ) {
        self.backgroundColorHex = backgroundColorHex
        self.showFavorites = showFavorites
        self.showFrequentlyVisited = showFrequentlyVisited
    }
}

/// Persists one profile's StartPageSettings, loaded/saved by profile name on
/// demand -- same shape as BlockingSettingsStore (see that file's doc
/// comment for why this is a per-profile-file store rather than one shared
/// singleton like ProfileManager/RoutingRulesStore).
enum StartPageSettingsStore {
    static func load(forProfileName profileName: String) -> StartPageSettings {
        guard let data = try? Data(contentsOf: fileURL(forProfileName: profileName)),
              let decoded = try? JSONDecoder().decode(StartPageSettings.self, from: data) else {
            return StartPageSettings()
        }
        return decoded
    }

    static func save(_ settings: StartPageSettings, forProfileName profileName: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        let url = fileURL(forProfileName: profileName)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL(forProfileName profileName: String) -> URL {
        URL(fileURLWithPath: CommandLineArgs.profilesRootPath())
            .appendingPathComponent(profileName)
            .appendingPathComponent("startpage.json")
    }
}
