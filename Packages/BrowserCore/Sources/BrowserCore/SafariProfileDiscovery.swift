import Foundation

/// Finds Safari 17+'s "Profiles" (browser-ymx's full Safari import). The
/// two-folders-per-profile layout (see `ProfileRecord`) was confirmed on a
/// real Mac by listing folder and file names only, never file contents.
public enum SafariProfileDiscovery {
    /// Lists every profile's UUID by looking for the `Profiles/<uuid>/`
    /// layout -- each subdirectory of `safariDirectory`'s `Profiles`
    /// folder is one profile, named by its own UUID. Returns an empty
    /// array (not an error) if there's no `Profiles` folder at all, which
    /// is the normal, expected case for a Safari installation that has
    /// never had a named profile created -- there's still a "default"
    /// profile in that case, it's just whatever lives directly at
    /// `safariDirectory`'s own top level (History.db, Bookmarks.plist),
    /// not a subdirectory of `Profiles`.
    public static func discoverProfileIds(safariDirectory: URL) -> [String] {
        let profilesDir = safariDirectory.appendingPathComponent("Profiles")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// One profile row from `SafariTabs.db`. Safari gives each profile two
    /// folders under `Profiles/`: one named by `id` (external_uuid), which
    /// holds only TopSites.plist, and one named by `dataFolderId`
    /// (server_id), which holds History.db and the rest of its data.
    public struct ProfileRecord: Equatable {
        public let id: String
        public let name: String
        public let dataFolderId: String?
        /// `Sync.ServerID` of the bookmark folder this profile shows as its
        /// Favorites (Safari Settings > Profiles > Favorites). Nil for the
        /// root profile, which uses the Favorites Bar.
        public let favoritesFolderServerId: String?

        public init(id: String, name: String, dataFolderId: String?, favoritesFolderServerId: String? = nil) {
            self.id = id
            self.name = name
            self.dataFolderId = dataFolderId
            self.favoritesFolderServerId = favoritesFolderServerId
        }
    }

    /// A Safari profile resolved against the `Profiles/` folders on disk.
    /// `id` is the stable key to store (external_uuid); `dataFolderId` is where its
    /// History.db lives, nil when it has no data folder on this Mac.
    public struct ResolvedProfile: Equatable {
        public let id: String
        public let name: String
        public let dataFolderId: String?
        public let favoritesFolderServerId: String?

        public init(id: String, name: String, dataFolderId: String?, favoritesFolderServerId: String? = nil) {
            self.id = id
            self.name = name
            self.dataFolderId = dataFolderId
            self.favoritesFolderServerId = favoritesFolderServerId
        }
    }

    /// external_uuid of the root profile's row. Its data lives at the Safari
    /// root, not under `Profiles/`, so it is never a resolved profile here.
    public static let defaultProfileRecordId = "DefaultProfile"

    /// Reads every profile row from a caller-supplied *copy* of
    /// `SafariTabs.db` -- same "never touch the live file" rule as
    /// `SafariHistoryReader`. `SafariTabs.db` is a single, top-level file
    /// (like Bookmarks.plist) covering every profile at once.
    ///
    /// Best-effort: returns an empty array (never throws) if the file can't
    /// be read or the schema doesn't match. Callers must treat missing
    /// metadata as unavailable rather than invent profiles from directories.
    /// A schema without `server_id` still yields rows, with no data folder.
    public static func profileRecords(fromCopiedSafariTabsDatabaseAt path: String) -> [ProfileRecord] {
        // SQLite may need to rebuild WAL bookkeeping in this private copy.
        guard FileManager.default.fileExists(atPath: path),
              let connection = try? SQLiteConnection(path: path) else { return [] }
        var columnNames: Set<String> = []
        if let columns = try? connection.prepare("SELECT name FROM pragma_table_info('bookmarks');") {
            while (try? columns.step()) == true { columnNames.insert(columns.text(0)) }
        }
        let hasServerId = columnNames.contains("server_id")
        let serverIdColumn = hasServerId ? "server_id" : "NULL"
        let attributesColumn = columnNames.contains("extra_attributes") ? "extra_attributes" : "NULL"
        guard let statement = try? connection.prepare("""
            SELECT external_uuid, title, \(serverIdColumn), \(attributesColumn) FROM bookmarks WHERE type = 1 AND subtype = 2;
            """) else { return [] }

        var records: [ProfileRecord] = []
        while (try? statement.step()) == true {
            let id = statement.text(0)
            guard !id.isEmpty else { continue }
            let dataFolderId = statement.text(2)
            records.append(ProfileRecord(
                id: id,
                name: statement.text(1),
                dataFolderId: dataFolderId.isEmpty ? nil : dataFolderId,
                favoritesFolderServerId: statement.dataOrNil(3).flatMap(favoritesFolderServerId(fromExtraAttributes:))
            ))
        }
        return records
    }

    /// `extra_attributes` is a property list; the Favorites folder choice is
    /// its `CustomFavoritesFolderServerID` key.
    static func favoritesFolderServerId(fromExtraAttributes data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let value = plist?["CustomFavoritesFolderServerID"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Joins profile rows to the `Profiles/` folder names on disk. Every row
    /// except the root profile's becomes one profile, named by its title and
    /// pointing at its data folder (server_id, or external_uuid when no
    /// server_id folder exists). Unclaimed directories may be caches or
    /// deleted profiles, so only Safari's metadata establishes a profile.
    /// UUIDs compare case-insensitively: nothing guarantees one case.
    public static func resolveProfiles(records: [ProfileRecord], folderIds: [String]) -> [ResolvedProfile] {
        var foldersByKey: [String: String] = [:]
        for folder in folderIds { foldersByKey[folder.uppercased()] = folder }
        var resolved: [ResolvedProfile] = []

        for record in records where record.id.uppercased() != defaultProfileRecordId.uppercased() {
            let dataFolder = record.dataFolderId.flatMap { foldersByKey[$0.uppercased()] }
                ?? foldersByKey[record.id.uppercased()]
            resolved.append(ResolvedProfile(
                id: record.id,
                name: record.name.isEmpty ? record.id : record.name,
                dataFolderId: dataFolder,
                favoritesFolderServerId: record.favoritesFolderServerId
            ))
        }
        return resolved
    }
}
