import Foundation

extension Notification.Name {
    /// Posted whenever ProfileManager's persisted profile list changes
    /// (create/rename/recolor/delete) -- lets MainMenuBuilder keep the
    /// Profiles menu in sync without ProfileManager needing to know about
    /// menus, and lets the Settings window's Profiles pane and Routing
    /// Rules pane (which shows profile names) refresh themselves regardless
    /// of which one triggered the change.
    static let profileManagerDidChange = Notification.Name("ProfileManagerDidChange")
}

/// Profiles persisted as JSON under
/// CommandLineArgs.sessionAndProfilesMetadataDirectory() -- normally
/// `~/Library/Application Support/Browser/profiles.json`, but an explicit
/// `--profiles-root <path>` launch fully redirects this alongside
/// SessionStore's session.json (browser-1rp -- previously both were
/// hardcoded regardless of that flag, so every "isolated" test launch
/// actually read and wrote Brady's real session/profile state). This is the
/// single source of truth for what profiles exist and their display identity
/// (name, color); it is independent of BRWEngine's profile-id ->
/// CefRequestContext map, which keys its cache directory by a profile's
/// immutable `id` (browser-ojw), not its mutable `name`, under
/// CommandLineArgs.profilesRootPath() (the sibling, CEF-facing path -- see
/// that function's own doc comment for why it isn't the same directory as
/// this one).
final class ProfileManager {
    static let shared = ProfileManager()

    /// The only profile a brand-new install starts with, and the fallback
    /// for a link that matches no rule while no browser window is open.
    static let bootstrapProfileName = "Personal"

    private let fileURL: URL
    private(set) var profiles: [Profile] = []

    /// True only while `init` itself is still running (browser-2bj). A
    /// brand-new profiles directory makes `init` call createProfile() ->
    /// save() -> post .profileManagerDidChange synchronously, and
    /// MainMenuBuilder's own observer for that notification touches
    /// `ProfileManager.shared` again to rebuild the Profiles menu -- while
    /// `shared`'s lazy `static let` initializer is still on the stack,
    /// which crashes (libdispatch: "trying to lock recursively"). Existing
    /// installs never hit this (profiles.json already has an entry, so
    /// `init` never calls createProfile() at all) -- only a genuinely fresh
    /// profiles directory (a new user, or any agent's fresh --profiles-root
    /// test) does, which is why it went unnoticed until now. Suppressing
    /// the post while this is true isn't losing information: nothing
    /// observing this notification exists yet in a way that needs it --
    /// MainMenuBuilder's own initial `build()` call reads
    /// `ProfileManager.shared.profiles` directly, after `shared` has
    /// finished constructing, so it already sees the freshly-bootstrapped
    /// default profile without needing to be told.
    private var isBootstrapping = true

    private init() {
        let dir = URL(fileURLWithPath: CommandLineArgs.sessionAndProfilesMetadataDirectory())
        fileURL = dir.appendingPathComponent("profiles.json")
        load()
        if profiles.isEmpty {
            _ = createProfile(name: Self.bootstrapProfileName, colorHex: ProfileColorPalette.hexValues[7])
        }
        // Every profile is now known (existing or freshly bootstrapped) --
        // the one point in the app's lifecycle before anything (CEF's own
        // cache_path, BrowserCore's browser.db, any of the per-profile JSON
        // stores) has touched a profile directory yet, so this is the only
        // safe place to migrate browser-ojw's old name-keyed layout to the
        // new id-keyed one without racing a store that's already reading/
        // writing under one name or the other.
        migrateNameKeyedDirectoriesIfNeeded()
        isBootstrapping = false
    }

    /// One-time upgrade from this app's original layout (every per-profile
    /// directory/file keyed by the profile's mutable `name`) to the current
    /// one (keyed by its immutable `id` -- browser-ojw). Renaming a profile
    /// used to require a best-effort directory move (see this file's git
    /// history) and left an already-open window pointing at stale storage
    /// until reopened; keying by id removes the need for that move at all.
    ///
    /// Per-profile, and each move is a single `FileManager.moveItem` --
    /// atomic on the same volume (which this always is, both paths sharing
    /// one `profilesRootPath()` parent), so a kill mid-migration can only
    /// ever leave some profiles still name-keyed, never a half-moved single
    /// profile's directory. Those remaining profiles are simply retried (and
    /// succeed) on the next launch -- no data is ever lost, just possibly
    /// deferred by one relaunch.
    ///
    /// Skips (rather than guesses) anything ambiguous: if a profile's old
    /// name-keyed directory doesn't exist, there's nothing to migrate
    /// (already done, or a genuinely new profile that's never had one). If
    /// *both* the old and new paths already exist, this doesn't know which
    /// one is authoritative -- overwriting either risks real data loss --
    /// so it's left alone entirely, logged, for a human to sort out.
    private func migrateNameKeyedDirectoriesIfNeeded() {
        let root = CommandLineArgs.profilesRootPath()
        for profile in profiles {
            // The decision lives in BrowserCore (browser-le4) so its rules are
            // covered by `swift test` instead of only by launching the app --
            // this loop just carries out whatever it returns. Two of those
            // rules were missing while the decision was inline here: a profile
            // whose name isn't a single path component (".." or "a/b") used to
            // resolve OUTSIDE the profiles root, so a migration could move a
            // directory this app doesn't own; and a profile whose name equals
            // its id used to attempt a move onto itself.
            let outcome = ProfileDirectoryMigration.outcome(
                profilesRoot: root,
                profileId: profile.id,
                profileName: profile.name,
                directoryExists: { FileManager.default.fileExists(atPath: $0) }
            )
            switch outcome {
            case .nothingToMigrate:
                continue
            case .ambiguous(let from, let to):
                NSLog("Browser: profile '%@' has both a name-keyed (%@) and id-keyed (%@) directory -- skipping migration, needs manual resolution",
                      profile.name, from, to)
            case .move(let from, let to):
                do {
                    try FileManager.default.moveItem(atPath: from, toPath: to)
                } catch {
                    NSLog("Browser: failed to migrate profile '%@' directory from %@ to %@: %@",
                          profile.name, from, to, String(describing: error))
                }
            }
        }
    }

    // A profiles.json that no longer decodes is moved aside by JSONFile
    // rather than overwritten: init then creates a fresh default profile,
    // and without the preserved copy every id-keyed profile directory would
    // be orphaned for good.
    private func load() {
        profiles = JSONFile<[Profile]>(url: fileURL).load(default: [])
    }

    private func save() {
        JSONFile<[Profile]>(url: fileURL).save(profiles)
        // See isBootstrapping's own doc comment (browser-2bj) -- never
        // skipped outside of init() itself, so every real create/rename/
        // recolor/delete after launch still notifies exactly as before.
        guard !isBootstrapping else { return }
        NotificationCenter.default.post(name: .profileManagerDidChange, object: self)
    }

    /// Where anything with no profile of its own lands: a link that matches
    /// no rule while no window is open, ⌘N with no window, a CLI command
    /// with no `--profile`. It is the Routing pane's configured fallback,
    /// which RoutingRulesStore keeps pointing at a profile that exists.
    var fallbackProfile: Profile {
        profile(id: RoutingRulesStore.shared.defaultProfileId) ?? profiles[0]
    }

    /// The configured fallback's replacement when it no longer exists (or
    /// was never set): the bootstrap profile if there is one, else the first.
    /// `profiles` is never empty -- init bootstraps one and deleteProfiles
    /// refuses to remove the last.
    var implicitFallbackProfile: Profile {
        profile(named: Self.bootstrapProfileName) ?? profiles[0]
    }

    func profile(named name: String) -> Profile? {
        profiles.first { $0.name == name }
    }

    /// Looked up by stable `id` (not the mutable display `name`) -- this is
    /// what routing rules key on (RoutingRule.Action.profileId), so a rule
    /// stays valid even if profile renaming is added later.
    func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Looks up a profile by name, auto-creating it if missing -- this is
    /// what keeps the `--profile <name>` launch argument working for any
    /// name, per AGENTS.md.
    @discardableResult
    func profileOrCreate(named name: String) -> Profile {
        if let existing = profile(named: name) {
            return existing
        }
        return createProfile(name: name, colorHex: nextUnusedColor())
    }

    @discardableResult
    func createProfile(name: String, colorHex: String) -> Profile {
        let profile = Profile(id: UUID().uuidString, name: name, colorHex: colorHex)
        profiles.append(profile)
        save()
        return profile
    }

    func nextUnusedColor() -> String {
        let used = Set(profiles.map { $0.colorHex })
        return ProfileColorPalette.hexValues.first { !used.contains($0) }
            ?? ProfileColorPalette.hexValues[profiles.count % ProfileColorPalette.hexValues.count]
    }

    /// Renames a profile and/or changes its color in place, preserving its
    /// stable `id` (routing rules and anything else keyed on id are
    /// unaffected). A profile's on-disk directories (CEF's own cache_path,
    /// BrowserCore's browser.db, and every per-profile JSON store) are keyed
    /// by that same immutable `id`, not by `name` (browser-ojw) -- so a
    /// rename is purely this metadata update, with no directory to move and
    /// no already-open window left pointing at stale storage the way a
    /// name-keyed rename used to.
    func updateProfile(id: String, name: String, colorHex: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        profiles[index].colorHex = colorHex
        save()
    }

    /// Deletes a profile's persisted entry and its on-disk cache directory.
    /// Refuses to delete the last remaining profile (returns false; Browser
    /// always needs at least one profile to launch into). This only touches
    /// ProfileManager's own state and the filesystem -- callers must close
    /// any open windows for this profile *before* calling this (see
    /// WindowManager.closeAllWindows(forProfileId:)), so CEF isn't left
    /// operating against a cache directory that's just been removed.
    @discardableResult
    func deleteProfile(id: String) -> Bool {
        deleteProfiles(ids: [id])
    }

    /// Bulk counterpart to `deleteProfile(id:)`. The profile list is changed
    /// and persisted once, so observers never see a half-deleted batch.
    /// Unknown IDs are ignored, but the operation is rejected if it would
    /// remove every remaining profile.
    @discardableResult
    func deleteProfiles(ids: Set<String>) -> Bool {
        let profilesToDelete = profiles.filter { ids.contains($0.id) }
        guard !profilesToDelete.isEmpty, profilesToDelete.count < profiles.count else { return false }

        profiles.removeAll { ids.contains($0.id) }
        save()

        let root = URL(fileURLWithPath: CommandLineArgs.profilesRootPath())
        for profile in profilesToDelete {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(profile.id))
        }
        return true
    }
}
