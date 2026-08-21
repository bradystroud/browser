import Foundation

/// One profile's history/bookmarks/downloads/reading-list stores, all backed by the same
/// `browser.db` (see BrowserCore's Database).
final class ProfileDataStores {
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let downloads: DownloadStore
    let readingList: ReadingListStore

    init(database: Database) {
        history = HistoryStore(database: database)
        bookmarks = BookmarkStore(database: database)
        downloads = DownloadStore(database: database)
        readingList = ReadingListStore(database: database)
        // Any download row still non-terminal on disk belongs to a previous
        // run -- the app was quit or killed mid-transfer, and nothing will
        // ever finish it (browser-s24). This is the one moment that is
        // provably safe to say so: a profile's stores are built lazily, on
        // first use, which for downloads is the store lookup inside
        // DownloadCoordinator.beginDownload -- i.e. always before this run's
        // first row exists, and only ever once per profile per run.
        try? downloads.reconcileUnfinished()
    }
}

/// Lazily opens and caches one `ProfileDataStores` per profile, keyed by
/// `Profile.id`. The database file lives at
/// `<profilesRootPath>/<profile.id>/browser.db` -- the same per-profile
/// directory BRWEngine already uses for that profile's CEF cache_path (see
/// CommandLineArgs.profileDirectory / BRWEngine.mm's GetOrCreateProfileContext),
/// keyed by the profile's immutable id, not its mutable display name
/// (browser-ojw).
final class ProfileDataStoreManager {
    static let shared = ProfileDataStoreManager()

    private var cache: [String: ProfileDataStores] = [:]

    private init() {}

    func stores(for profile: Profile) -> ProfileDataStores {
        if let existing = cache[profile.id] {
            return existing
        }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profile.id))
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
            fatalError("Browser: failed to open BrowserCore database for profile \(profile.name) (id: \(profile.id)): \(error)")
        }
    }
}
