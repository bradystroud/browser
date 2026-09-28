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
        let sharedBookmarks: [ImportedBookmarkNode]
        let bookmarkCount: Int
        let favoriteCount: Int
        let profiles: [SafariImportProfile]
    }

    private static let candidateRoots: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari"),
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Safari"),
    ]

    static func scan() throws -> Result {
        let fm = FileManager.default
        guard let root = candidateRoots.first(where: { root in
            fm.fileExists(atPath: root.appendingPathComponent("Bookmarks.plist").path)
                || fm.fileExists(atPath: root.appendingPathComponent("Profiles").path)
        }) else {
            throw ScanError.safariDataNotReadable
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("SafariImport-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Best-effort, not fatal: a root directory that exists but has an
        // unparseable/missing Bookmarks.plist should still let history come
        // through, per this import's per-data-type resilience.
        let sharedBookmarks = (try? SafariBookmarksPlistParser.parse(fileURL: root.appendingPathComponent("Bookmarks.plist"))) ?? []
        let bookmarkCounts = countBookmarksAndFavorites(in: sharedBookmarks)

        var profileNames: [String: String] = [:]
        let tabsDbSource = root.appendingPathComponent("SafariTabs.db")
        if fm.fileExists(atPath: tabsDbSource.path) {
            let copiedTabsPath = tempDir.appendingPathComponent("SafariTabs.db").path
            if copySQLiteDatabase(from: tabsDbSource.path, to: copiedTabsPath) {
                profileNames = SafariProfileDiscovery.profileNames(fromCopiedSafariTabsDatabaseAt: copiedTabsPath)
            }
        }

        var profiles: [SafariImportProfile] = [
            makeProfile(
                id: defaultProfileId,
                displayName: "Safari Default",
                sourceHistoryPath: root.appendingPathComponent("History.db"),
                copiedHistoryName: "Default-History.db",
                tempDir: tempDir
            )
        ]

        let profileIds = SafariProfileDiscovery.discoverProfileIds(safariDirectory: root)
        for profileId in profileIds {
            profiles.append(makeProfile(
                id: profileId,
                displayName: profileNames[profileId.uppercased()] ?? profileId,
                sourceHistoryPath: root.appendingPathComponent("Profiles").appendingPathComponent(profileId).appendingPathComponent("History.db"),
                copiedHistoryName: "\(profileId)-History.db",
                tempDir: tempDir
            ))
        }

        return Result(
            tempDirectory: tempDir,
            sharedBookmarks: sharedBookmarks,
            bookmarkCount: bookmarkCounts.bookmarks,
            favoriteCount: bookmarkCounts.favorites,
            profiles: profiles
        )
    }

    /// Copies a SQLite database together with its -wal and -shm files.
    /// Safari keeps its databases open in WAL mode, so recent rows -- a
    /// newly created or renamed profile's name, the latest visits -- often
    /// exist only in the -wal file until Safari checkpoints it. Copying the
    /// main file alone silently drops them.
    private static func copySQLiteDatabase(from source: String, to destination: String) -> Bool {
        let fm = FileManager.default
        guard (try? fm.copyItem(atPath: source, toPath: destination)) != nil else { return false }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: source + suffix) {
            try? fm.copyItem(atPath: source + suffix, toPath: destination + suffix)
        }
        return true
    }

    private static func makeProfile(id: String, displayName: String, sourceHistoryPath: URL, copiedHistoryName: String, tempDir: URL) -> SafariImportProfile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceHistoryPath.path) else {
            return SafariImportProfile(id: id, displayName: displayName, historyDatabasePath: nil, historyCount: 0)
        }
        let copiedPath = tempDir.appendingPathComponent(copiedHistoryName).path
        guard copySQLiteDatabase(from: sourceHistoryPath.path, to: copiedPath) else {
            return SafariImportProfile(id: id, displayName: displayName, historyDatabasePath: nil, historyCount: 0)
        }
        let visitCount = (try? SafariHistoryReader.readVisits(fromCopiedDatabaseAt: copiedPath))?.count ?? 0
        return SafariImportProfile(id: id, displayName: displayName, historyDatabasePath: copiedPath, historyCount: visitCount)
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
