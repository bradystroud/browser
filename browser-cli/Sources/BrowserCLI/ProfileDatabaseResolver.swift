import Foundation
import BrowserCore

/// Shared by `history search` and `bookmarks list`: resolves a `--profile
/// <name>` (defaulting to "default", matching `ProfileManager.
/// defaultProfileName`) against the profiles this `--profiles-root` actually
/// knows about, and opens that profile's real `browser.db` -- the same
/// `Database`/`HistoryStore`/`BookmarkStore` classes the app itself uses
/// (`Sources/App/Furniture/ProfileDataStores.swift`), not a parallel
/// read-only reimplementation, so there's exactly one copy of the schema/
/// query logic. Safe to open alongside a running app: `Database.init` sets
/// `journal_mode = WAL` (see BrowserCore's SQLiteConnection), which allows
/// concurrent readers across processes; this type never calls anything that
/// writes.
///
/// The directory itself is `<profilesRootPath>/<profile.id>`, keyed by the
/// profile's immutable UUID, not its mutable display name (browser-ojw) --
/// see `BrowserCore`'s `ProfilesRootResolver.profileDirectory(profilesRoot:
/// profileId:)`, the same function `Sources/App/Furniture/
/// ProfileDataStores.swift`'s `ProfileDataStoreManager` calls. This was
/// previously `<profilesRootPath>/<profile.name>`, from before that
/// migration landed -- caught by directly inspecting a live profile's
/// on-disk layout during the browser-82d network-access investigation, not
/// by a test (nothing here was pointed at the old, now-stale path to fail
/// loudly; it just silently found nothing, which read exactly like "this
/// profile has no history" instead of "wrong directory").
///
/// Deliberately checks `profiles.json` *before* opening a database --
/// `Database.init` itself would silently create an empty `browser.db` under
/// a typo'd profile name (it creates the profile directory if missing),
/// which would make a typo look like "this profile just has no history" instead
/// of the actually-more-useful "no such profile" error.
public enum ProfileDatabaseResolver {
    public static func resolve(profileNameFlag: String?, directory: String, profilesRootPath: String) throws -> (profile: ProfileRecord, database: Database) {
        let profiles = ProfileRecordStore.load(directory: directory)
        let requestedName = profileNameFlag ?? "default"
        guard let profile = profiles.first(where: { $0.name == requestedName }) else {
            let known = profiles.map(\.name).joined(separator: ", ")
            throw SimpleError("no profile named '\(requestedName)' (known profiles: \(known.isEmpty ? "none -- launch the app at least once first" : known))")
        }
        let profileDirectory = URL(fileURLWithPath: ProfilesRootResolver.profileDirectory(profilesRoot: profilesRootPath, profileId: profile.id))
        let database = try Database(profileDirectory: profileDirectory)
        return (profile, database)
    }
}
