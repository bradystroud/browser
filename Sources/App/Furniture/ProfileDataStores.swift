import Foundation

/// One profile's history/bookmarks/downloads stores, all backed by the same
/// `browser.db` (see BrowserCore's Database).
final class ProfileDataStores {
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let downloads: DownloadStore

    init(database: Database) {
        history = HistoryStore(database: database)
        bookmarks = BookmarkStore(database: database)
        downloads = DownloadStore(database: database)
    }
}

/// Lazily opens and caches one `ProfileDataStores` per profile, keyed by
/// `Profile.id`. The database file lives at
/// `<profilesRootPath>/<profile.name>/browser.db` -- the same per-profile
/// directory BRWEngine already uses for that profile's CEF cache_path (see
/// CommandLineArgs.profilesRootPath / BRWEngine.mm's GetOrCreateProfileContext),
/// keyed by `name` for the same reason BRWEngine is: names are the stable
/// per-profile identifier today (see Profile.swift -- no rename feature yet).
final class ProfileDataStoreManager {
    static let shared = ProfileDataStoreManager()

    private var cache: [String: ProfileDataStores] = [:]

    private init() {}

    func stores(for profile: Profile) -> ProfileDataStores {
        if let existing = cache[profile.id] {
            return existing
        }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profilesRootPath())
            .appendingPathComponent(profile.name)
        do {
            let database = try Database(profileDirectory: profileDirectory)
            let stores = ProfileDataStores(database: database)
            cache[profile.id] = stores
            return stores
        } catch {
            // BrowserCore's Database.init only throws on a genuine SQLite/
            // filesystem failure (bad permissions, disk full, corrupt file)
            // -- there's no reasonable degraded mode for history/bookmarks/
            // downloads, so surface it loudly rather than silently no-op-ing
            // every future call in this profile.
            fatalError("Browser: failed to open BrowserCore database for profile \(profile.name): \(error)")
        }
    }
}
