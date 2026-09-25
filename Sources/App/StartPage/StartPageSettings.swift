import Foundation

/// Per-profile start-page customization: background color (rendered as a
/// simple two-tone gradient from this color -- see StartPageRenderer), an
/// optional background image that takes the color's place, and which sections
/// show. Codable, persisted as startpage.json inside that profile's own cache
/// directory, mirroring BlockingSettingsStore's exact pattern
/// (root_cache_path/<profile id>/startpage.json -- browser-ojw).
struct StartPageSettings: Codable, Equatable {
    var backgroundColorHex: String
    var showFavorites: Bool
    var showFrequentlyVisited: Bool
    /// The background image's file name inside this profile's own directory,
    /// or nil for none (browser-1wo). Only ever
    /// StartPageBackgroundImageStore.fileName -- stored by name rather than as
    /// a bare flag so the file this refers to stays readable from the JSON
    /// alone, and relative rather than absolute so it keeps resolving after
    /// browser-ojw's profile-directory migration renames the directory around
    /// it. The color above is kept alongside it and comes back if the image is
    /// removed.
    var backgroundImageFileName: String?

    init(
        backgroundColorHex: String = ProfileColorPalette.hexValues[7],
        showFavorites: Bool = true,
        showFrequentlyVisited: Bool = true,
        backgroundImageFileName: String? = nil
    ) {
        self.backgroundColorHex = backgroundColorHex
        self.showFavorites = showFavorites
        self.showFrequentlyVisited = showFrequentlyVisited
        self.backgroundImageFileName = backgroundImageFileName
    }
}

/// Persists one profile's StartPageSettings, loaded/saved by profile id on
/// demand -- same shape as BlockingSettingsStore (see that file's doc
/// comment for why this is a per-profile-file store rather than one shared
/// singleton like ProfileManager/RoutingRulesStore).
enum StartPageSettingsStore {
    static func load(forProfileId profileId: String) -> StartPageSettings {
        file(forProfileId: profileId).load(default: StartPageSettings())
    }

    static func save(_ settings: StartPageSettings, forProfileId profileId: String) {
        file(forProfileId: profileId).save(settings)
    }

    private static func file(forProfileId profileId: String) -> JSONFile<StartPageSettings> {
        JSONFile(url: URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            .appendingPathComponent("startpage.json"))
    }
}
