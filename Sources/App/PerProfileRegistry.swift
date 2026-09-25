import AppKit

/// A window the app keeps at most one of per profile -- History, Bookmarks,
/// Reading List, Downloads.
protocol ProfileWindowController: AnyObject {
    init(profile: Profile)
    func show()
}

/// One controller per profile, reused across `show(for:)` calls rather than
/// spawning a duplicate window every time the shortcut or menu item fires
/// again for the same profile. Controllers are never released, so closing
/// the window only hides it, same as SettingsWindowController's singleton.
final class ProfileWindowRegistry<Controller: ProfileWindowController> {
    private var controllers: [String: Controller] = [:]

    func show(for profile: Profile) {
        let controller = controllers[profile.id] ?? {
            let created = Controller(profile: profile)
            controllers[profile.id] = created
            return created
        }()
        controller.show()
    }
}

/// Lazily opens and caches one store per profile, keyed by the profile's
/// immutable id (browser-ojw), the same way ProfileDataStoreManager does for
/// the SQLite stores.
final class ProfileStoreCache<Store> {
    private let makeStore: (URL) -> Store
    private var cache: [String: Store] = [:]

    /// `makeStore` receives the profile's own directory.
    init(_ makeStore: @escaping (URL) -> Store) {
        self.makeStore = makeStore
    }

    func store(for profile: Profile) -> Store {
        store(forProfileId: profile.id)
    }

    func store(forProfileId profileId: String) -> Store {
        if let existing = cache[profileId] {
            return existing
        }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
        // Usually already created by BrowserCore's Database or CEF's own
        // cache_path by the time this runs, but not guaranteed to run after
        // either -- ensured here too so a fresh profile with no history/
        // bookmarks activity yet still gets a writable directory.
        try? FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let store = makeStore(profileDirectory)
        cache[profileId] = store
        return store
    }
}
