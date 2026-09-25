import Foundation
import BrowserCore

/// Shared by `history search` and `bookmarks list`: resolves a `--profile
/// <name>` (defaulting to "default", matching `ProfileManager.
/// defaultProfileName`) against the profiles this `--profiles-root` actually
/// knows about, and opens that profile's real `browser.db` with the same
/// `Database`/`HistoryStore`/`BookmarkStore` classes the app uses, so there
/// is one copy of the schema and query logic.
///
/// The database is opened read-only and never migrated (see
/// `Database.openExistingReadOnly`), so it is safe alongside a running app.
/// The directory is keyed by the profile's immutable id, never its name
/// (`ProfilesRootResolver.profileDirectory`).
///
/// Checks `profiles.json` before opening anything, so a typo'd profile name
/// reports "no such profile" rather than looking like an empty history.
public enum ProfileDatabaseResolver {
    public static func resolve(profileNameFlag: String?, directory: String, profilesRootPath: String) throws -> (profile: ProfileRecord, database: Database) {
        let profiles = ProfileRecordStore.load(directory: directory)
        let requestedName = profileNameFlag ?? "default"
        guard let profile = profiles.first(where: { $0.name == requestedName }) else {
            let known = profiles.map(\.name).joined(separator: ", ")
            throw SimpleError("no profile named '\(requestedName)' (known profiles: \(known.isEmpty ? "none -- launch the app at least once first" : known))")
        }
        let profileDirectory = URL(fileURLWithPath: ProfilesRootResolver.profileDirectory(profilesRoot: profilesRootPath, profileId: profile.id))
        let database: Database
        do {
            database = try Database.openExistingReadOnly(profileDirectory: profileDirectory)
        } catch {
            throw SimpleError("profile '\(requestedName)' has no history or bookmarks database yet -- open it in the app at least once first (\(error))")
        }
        return (profile, database)
    }
}
