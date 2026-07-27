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
/// ~/Library/Application Support/Browser/profiles.json. This is the single
/// source of truth for what profiles exist and their display identity (name,
/// color); it is independent of BRWEngine's profile-name -> CefRequestContext
/// map, which just needs a profile's `name` to key its cache directory.
final class ProfileManager {
    static let shared = ProfileManager()

    static let defaultProfileName = "default"

    private let fileURL: URL
    private(set) var profiles: [Profile] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Browser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")
        load()
        if profiles.isEmpty {
            _ = createProfile(name: Self.defaultProfileName, colorHex: ProfileColorPalette.hexValues[7])
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: .profileManagerDidChange, object: self)
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
    /// unaffected). A profile's on-disk cache directory is keyed by its
    /// *name*, not its id (see Sources/Bridge/BRWEngine.mm: `cache_path =
    /// root_cache_path + "/" + profile_name`), so a rename best-effort moves
    /// that directory too, so a future window opened under the new name
    /// still finds the existing cookies/history/cache. This is best-effort,
    /// not guaranteed: a window already open for this profile at rename time
    /// keeps operating on its already-opened file handles regardless (POSIX
    /// rename-of-an-open-directory is safe), but that window's title bar and
    /// menu label were captured at open time and won't reflect the new name
    /// until it's closed and reopened.
    func updateProfile(id: String, name: String, colorHex: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let oldName = profiles[index].name
        if oldName != name {
            let root = URL(fileURLWithPath: CommandLineArgs.profilesRootPath())
            try? FileManager.default.moveItem(at: root.appendingPathComponent(oldName), to: root.appendingPathComponent(name))
        }
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
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let name = profiles[index].name
        profiles.remove(at: index)
        save()
        let root = URL(fileURLWithPath: CommandLineArgs.profilesRootPath())
        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        return true
    }
}
