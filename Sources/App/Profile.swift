import Foundation

/// A browser profile identity. Each window belongs to exactly one profile
/// (per-window profile identity, see docs/plans/2026-07-27-browser-plan.md);
/// `id` (immutable) is the BRWBrowser/CefRequestContext key, so profile
/// cache data lives at root_cache_path/<id>, not root_cache_path/<name>
/// (see BRWEngine.mm) -- `name` is a mutable display label only (see
/// ProfileManager.updateProfile), never used to key any on-disk storage
/// (browser-ojw; see ProfileManager.migrateNameKeyedDirectoriesIfNeeded()
/// for the one-time upgrade from this app's earlier name-keyed layout).
struct Profile: Codable, Equatable {
    let id: String
    var name: String
    var colorHex: String
}

/// Fixed palette offered when creating a new profile -- Apple's system accent
/// hues, so swatches read as native rather than arbitrary.
enum ProfileColorPalette {
    static let hexValues: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE",
        "#30B0C7", "#32ADE6", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55",
    ]
}
