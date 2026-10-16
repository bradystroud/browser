import Foundation

/// One Safari profile candidate for the "Import from Safari…" picker
/// (browser-ymx), with counts pre-computed so the picker never has to touch
/// the filesystem itself.
struct SafariImportProfile {
    let id: String
    let displayName: String
    /// Path to a *copy* of this profile's History.db in the scan's temp
    /// directory -- nil if Safari had no History.db for this profile (a
    /// brand-new named profile that's never been browsed in yet).
    let historyDatabasePath: String?
    let historyCount: Int
    let historyReadFailed: Bool
    /// This profile's share of Safari's one bookmark tree -- see
    /// SafariImportScanner.bookmarks(for:in:).
    let bookmarks: [ImportedBookmarkNode]
    let bookmarkCount: Int
    let favoriteCount: Int

    var hasUnavailableOnlyData: Bool { historyReadFailed && bookmarkCount == 0 }
}

/// Locates Safari's on-disk data, copies the relevant files to a temp
/// directory, and produces per-profile counts for the "Import from
/// Safari…" picker (browser-ymx) -- never opens any of Safari's live files
/// directly (see SafariHistoryReader/SafariBookmarksPlistParser's own
/// contracts). See docs/ai-tasks/safari-import-notes.md for what's verified
/// vs. triangulated about this layout, and why bookmarks/favourites are one
/// shared tree rather than counted per profile.
enum SafariImportScanner {
    /// Sentinel id for whatever lives directly at Safari's top level
    /// (History.db/Bookmarks.plist) -- present on every Safari install
    /// regardless of whether named Profiles exist, so it's always included
    /// alongside any real Profiles/<uuid> entries. Not a real UUID, so it
    /// can never collide with one.
    static let defaultProfileId = "safari-default"

    enum ScanError: Error {
        /// Neither candidate root directory was even readable. Confirmed
        /// empirically (see safari-import-notes.md) that this is exactly
        /// what a TCC/Full-Disk-Access denial looks like here too -- same
        /// indistinguishable-from-"not installed" failure mode
        /// SafariBookmarksPlistParser.ReadError.fileNotReadable already
        /// documents, so callers should show the same explanatory dialog.
        case safariDataNotReadable
    }

    struct Result {
        /// Caller-owned; remove this once the picker window closes (either
        /// after a completed import or on cancel) -- scan() itself can't
        /// clean it up, since these copied files are what the later import
        /// step reads from.
        let tempDirectory: URL
        let profiles: [SafariImportProfile]
        let profileMetadataUnavailable: Bool
    }

    private static let candidateRoots: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari"),
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Safari"),
    ]

    /// One Safari profile and the live file its history is read from.
    struct ProfileSource {
        /// `defaultProfileId` for the root profile, else the profile's
        /// external_uuid -- stable across renames, so it is the key to store.
        let id: String
        let displayName: String
        /// `Sync.ServerID` of the bookmark folder this profile uses as its
        /// Favorites; the root profile's is the Favorites Bar.
        let favoritesFolderServerId: String?
        /// Live History.db path, nil when this profile has no history on this
        /// Mac. Read it only through `copySQLiteDatabase`, never directly.
        let historyPath: URL?
    }

    /// Every Safari file this app reads, located across both candidate
    /// directories. Modern Safari splits its data: `SafariTabs.db` and
    /// `Profiles/` live in the container, while the root profile's
    /// History.db and Bookmarks.plist can still live in ~/Library/Safari. So
    /// each file is looked up on its own, never "pick one directory".
    struct Sources {
        let bookmarksPlist: URL?
        let profiles: [ProfileSource]
        let profileMetadataUnavailable: Bool
    }

    /// Candidate Safari directories. `--safari-data-root <dir>` replaces both,
    /// so a scratch launch can import and sync from a synthetic fixture
    /// instead of the real Safari data.
    private static func roots() -> [URL] {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--safari-data-root"), arguments.indices.contains(index + 1) {
            return [URL(fileURLWithPath: arguments[index + 1])]
        }
        return candidateRoots
    }

    /// Nil when nothing is readable -- which is also what a missing Full
    /// Disk Access grant looks like. `SafariTabs.db` is copied into
    /// `tempDirectory` to read profile names, and removed again.
    static func locateSources(tempDirectory: URL, safariDirectories: [URL]? = nil) -> Sources? {
        let fm = FileManager.default
        let roots = safariDirectories ?? roots()
        func first(_ relativePath: String) -> URL? {
            roots.map { $0.appendingPathComponent(relativePath) }.first { fm.isReadableFile(atPath: $0.path) }
        }

        let bookmarks = first("Bookmarks.plist")
        let rootHistory = first("History.db")
        let folderIds = Array(Set(roots.flatMap {
            SafariProfileDiscovery.discoverProfileIds(safariDirectory: $0)
        })).sorted()
        guard bookmarks != nil || rootHistory != nil || !folderIds.isEmpty else { return nil }

        var records: [SafariProfileDiscovery.ProfileRecord] = []
        for tabsDb in roots.map({ $0.appendingPathComponent("SafariTabs.db") }) where fm.isReadableFile(atPath: tabsDb.path) {
            let copiedTabsPath = tempDirectory.appendingPathComponent("SafariTabs-\(UUID().uuidString).db").path
            if copySQLiteDatabase(from: tabsDb.path, to: copiedTabsPath) {
                records = SafariProfileDiscovery.profileRecords(fromCopiedSafariTabsDatabaseAt: copiedTabsPath)
            }
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: copiedTabsPath + suffix) }
            if !records.isEmpty { break }
        }
        // Folder names do not identify Safari profiles. If metadata cannot
        // be read, keep the main profile's readable data and tell the caller
        // that named profiles are unavailable.
        let profileMetadataUnavailable = !folderIds.isEmpty && records.isEmpty
        let rootName = records.first {
            $0.id.caseInsensitiveCompare(SafariProfileDiscovery.defaultProfileRecordId) == .orderedSame
        }?.name

        var profiles = [ProfileSource(
            id: defaultProfileId,
            displayName: rootName.flatMap { $0.isEmpty ? nil : $0 } ?? "Safari Default",
            favoritesFolderServerId: SafariBookmarksPlistParser.favoritesBarServerId,
            historyPath: rootHistory
        )]
        for resolved in SafariProfileDiscovery.resolveProfiles(records: records, folderIds: folderIds) {
            let history = resolved.dataFolderId.flatMap { first("Profiles/\($0)/History.db") }
            profiles.append(ProfileSource(
                id: resolved.id,
                displayName: resolved.name,
                favoritesFolderServerId: resolved.favoritesFolderServerId,
                historyPath: history
            ))
        }
        return Sources(bookmarksPlist: bookmarks, profiles: profiles, profileMetadataUnavailable: profileMetadataUnavailable)
    }

    static func scan(safariDirectories: [URL]? = nil) throws -> Result {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("SafariImport-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let sources = locateSources(tempDirectory: tempDir, safariDirectories: safariDirectories) else {
            try? fm.removeItem(at: tempDir)
            throw ScanError.safariDataNotReadable
        }

        // Best-effort, not fatal: a missing or unparseable Bookmarks.plist
        // should still let history come through, per this import's
        // per-data-type resilience.
        let favoritesIds = Set(sources.profiles.compactMap(\.favoritesFolderServerId))
        let partition = sources.bookmarksPlist.flatMap {
            try? SafariBookmarksPlistParser.partition(fileURL: $0, favoritesFolderServerIds: favoritesIds)
        }

        let profiles = sources.profiles.enumerated().map { index, source in
            makeProfile(
                source: source,
                bookmarks: partition.map { bookmarks(for: source, in: $0) } ?? [],
                copiedHistoryName: "\(index)-History.db",
                tempDir: tempDir
            )
        }

        return Result(tempDirectory: tempDir, profiles: profiles, profileMetadataUnavailable: sources.profileMetadataUnavailable)
    }

    /// A profile's bookmarks: its Favorites folder, imported as this app's
    /// Favorites. The root profile also takes everything that is in no
    /// profile's Favorites (Bookmarks Menu and other top-level folders), so
    /// each bookmark is offered by exactly one row. A named profile whose
    /// folder isn't in the tree -- iCloud bookmarks off, or the folder was
    /// deleted -- gets none.
    static func bookmarks(for source: ProfileSource, in partition: SafariBookmarksPlistParser.Partition) -> [ImportedBookmarkNode] {
        var nodes: [ImportedBookmarkNode] = []
        if let favorites = source.favoritesFolderServerId.flatMap({ partition.favorites[$0] }), !favorites.isEmpty {
            nodes.append(.folder(title: "Favorites", isFavoritesBar: true, children: favorites))
        }
        if source.id == defaultProfileId {
            nodes += partition.remainder
        }
        return nodes
    }

    /// Copies the WAL before the database so a checkpoint between copies
    /// cannot leave a database that needs an uncopied WAL. The private copy
    /// rebuilds its own shared-memory index; Safari's live -shm isn't portable.
    static func copySQLiteDatabase(from source: String, to destination: String) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: source + "-wal") {
                try fm.copyItem(atPath: source + "-wal", toPath: destination + "-wal")
            }
            try fm.copyItem(atPath: source, toPath: destination)
            return true
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: destination + suffix)
            }
            return false
        }
    }

    private static func makeProfile(source: ProfileSource, bookmarks: [ImportedBookmarkNode], copiedHistoryName: String, tempDir: URL) -> SafariImportProfile {
        let counts = countBookmarksAndFavorites(in: bookmarks)
        func profile(historyPath: String?, historyCount: Int, historyReadFailed: Bool = false) -> SafariImportProfile {
            SafariImportProfile(
                id: source.id,
                displayName: source.displayName,
                historyDatabasePath: historyPath,
                historyCount: historyCount,
                historyReadFailed: historyReadFailed,
                bookmarks: bookmarks,
                bookmarkCount: counts.bookmarks,
                favoriteCount: counts.favorites
            )
        }
        let fm = FileManager.default
        guard let sourceHistoryPath = source.historyPath, fm.fileExists(atPath: sourceHistoryPath.path) else {
            return profile(historyPath: nil, historyCount: 0)
        }
        let copiedPath = tempDir.appendingPathComponent(copiedHistoryName).path
        guard copySQLiteDatabase(from: sourceHistoryPath.path, to: copiedPath) else {
            return profile(historyPath: nil, historyCount: 0, historyReadFailed: true)
        }
        do {
            let visitCount = try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: copiedPath).count
            return profile(historyPath: copiedPath, historyCount: visitCount)
        } catch {
            return profile(historyPath: nil, historyCount: 0, historyReadFailed: true)
        }
    }

    /// `favorites` counts only bookmark leaves nested (at any depth) inside
    /// a folder flagged `isFavoritesBar`; `bookmarks` counts every leaf,
    /// favourites included -- matching how the picker's "N bookmarks, M
    /// favourites" phrasing reads elsewhere in this app.
    private static func countBookmarksAndFavorites(in nodes: [ImportedBookmarkNode], insideFavoritesBar: Bool = false) -> (bookmarks: Int, favorites: Int) {
        var bookmarks = 0
        var favorites = 0
        for node in nodes {
            switch node {
            case .bookmark:
                bookmarks += 1
                if insideFavoritesBar { favorites += 1 }
            case .folder(_, let isFavoritesBar, let children):
                let nested = countBookmarksAndFavorites(in: children, insideFavoritesBar: insideFavoritesBar || isFavoritesBar)
                bookmarks += nested.bookmarks
                favorites += nested.favorites
            }
        }
        return (bookmarks, favorites)
    }

    /// Every bookmark URL that lives inside a folder flagged
    /// `isFavoritesBar`, at any depth -- lets a caller tell, after
    /// BookmarkImporter.importNodes(_:) hands back its flat list of newly
    /// inserted URLs (which doesn't distinguish the two), which of those
    /// were favourites vs. regular bookmarks (SafariImportWindowController's
    /// final "N bookmarks, M favourites" summary).
    static func favoriteURLs(in nodes: [ImportedBookmarkNode], insideFavoritesBar: Bool = false) -> Set<String> {
        var result: Set<String> = []
        for node in nodes {
            switch node {
            case .bookmark(_, let url):
                if insideFavoritesBar { result.insert(url) }
            case .folder(_, let isFavoritesBar, let children):
                result.formUnion(favoriteURLs(in: children, insideFavoritesBar: insideFavoritesBar || isFavoritesBar))
            }
        }
        return result
    }
}
