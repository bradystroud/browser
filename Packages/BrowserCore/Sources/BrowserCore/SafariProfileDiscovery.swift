import Foundation

/// Finds Safari 17+'s "Profiles" (browser-ymx's full Safari import) --
/// see docs/ai-tasks/safari-import-notes.md for the full citation trail
/// behind this layout and its confidence level (medium: triangulated from
/// one actively-maintained, directly-read forensics tool's source, not an
/// Apple-documented format, and not independently verified on a live Mac
/// -- this machine's own ~/Library/Safari is itself TCC-protected even
/// for a plain directory listing).
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

    /// Resolves every discovered profile UUID to its display name (e.g.
    /// "Personal", "Work") by querying a caller-supplied *copy* of
    /// `SafariTabs.db` -- same "never touch the live file" rule as
    /// `SafariHistoryReader`. `SafariTabs.db` is a single, top-level file
    /// (like Bookmarks.plist) covering every profile at once, not split
    /// per profile.
    ///
    /// Best-effort: returns an empty dictionary (never throws) if the
    /// file can't be read or the schema doesn't match what's expected, so
    /// a caller can fall back to showing the raw UUID instead of failing
    /// the whole import over a name lookup.
    public static func profileNames(fromCopiedSafariTabsDatabaseAt path: String) -> [String: String] {
        guard let connection = try? SQLiteConnection(path: path, readOnly: true) else { return [:] }
        guard let statement = try? connection.prepare("""
            SELECT external_uuid, title FROM bookmarks WHERE parent = 0 AND type = 1 AND subtype = 2;
            """) else { return [:] }

        var names: [String: String] = [:]
        while (try? statement.step()) == true {
            let uuid = statement.text(0)
            let title = statement.text(1)
            guard !uuid.isEmpty, !title.isEmpty else { continue }
            names[uuid] = title
        }
        return names
    }
}
