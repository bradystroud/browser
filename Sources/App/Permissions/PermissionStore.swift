import Foundation

/// Per-profile, per-origin permission decisions, persisted as JSON at
/// `<profilesRootPath>/<profile.id>/permissions.json` -- the same
/// per-profile directory convention BrowserCore's browser.db and CEF's own
/// cache_path already use (see ProfileDataStores.swift), keyed by the
/// profile's immutable id, not its mutable display name (browser-ojw).
/// Deliberately a plain JSON file rather than a BrowserCore SQLite table --
/// this is a small key-value map with no querying/ranking/ordering needs,
/// matching RoutingRulesStore/ProfileManager's existing JSON-file pattern
/// rather than HistoryStore/BookmarkStore/DownloadStore's SQLite one.
final class PermissionStore {
    private let fileURL: URL
    /// origin -> kind raw value -> allowed.
    private var decisions: [String: [String: Bool]] = [:]

    init(profileDirectory: URL) {
        fileURL = profileDirectory.appendingPathComponent("permissions.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) else {
            decisions = [:]
            return
        }
        decisions = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func keys(for kinds: EnginePermissionKind) -> [String] {
        var keys: [String] = []
        if kinds.contains(.camera) { keys.append("camera") }
        if kinds.contains(.microphone) { keys.append("microphone") }
        if kinds.contains(.geolocation) { keys.append("geolocation") }
        if kinds.contains(.notifications) { keys.append("notifications") }
        return keys
    }

    /// Returns a remembered decision only if EVERY kind in `kinds` already
    /// has a stored decision for `origin`, and they all agree. A combined
    /// request where the individual kinds disagree (e.g. camera was allowed
    /// alone previously, microphone never asked) returns nil -- prompt again
    /// to resolve, rather than guessing which way the whole batch should go.
    func decision(for origin: String, kinds: EnginePermissionKind) -> Bool? {
        let keys = Self.keys(for: kinds)
        guard !keys.isEmpty, let originDecisions = decisions[origin] else { return nil }
        let values = keys.compactMap { originDecisions[$0] }
        guard values.count == keys.count else { return nil }
        if values.allSatisfy({ $0 }) { return true }
        if values.allSatisfy({ !$0 }) { return false }
        return nil
    }

    /// Records `allowed` for every kind in `kinds` at once -- a combined
    /// request's single decision applies to each individual kind it
    /// bundled, so a later single-kind request (e.g. camera alone, after
    /// camera+microphone were granted together) doesn't re-prompt either.
    func setDecision(_ allowed: Bool, for origin: String, kinds: EnginePermissionKind) {
        var originDecisions = decisions[origin] ?? [:]
        for key in Self.keys(for: kinds) {
            originDecisions[key] = allowed
        }
        decisions[origin] = originDecisions
        save()
    }

    /// Clears every remembered decision for every origin in this profile.
    /// No UI calls this yet -- see the follow-up bead for a Settings
    /// "Reset permissions" surface -- but the store itself is ready for it.
    func resetAll() {
        decisions = [:]
        save()
    }
}

/// Lazily opens and caches one `PermissionStore` per profile, keyed by
/// `Profile.id`, mirroring ProfileDataStoreManager's pattern.
final class PermissionStoreManager {
    static let shared = PermissionStoreManager()

    private var cache: [String: PermissionStore] = [:]

    private init() {}

    func store(for profile: Profile) -> PermissionStore {
        if let existing = cache[profile.id] {
            return existing
        }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profile.id))
        // Usually already created by BrowserCore's Database or CEF's own
        // cache_path by the time this runs, but not guaranteed to run after
        // either -- ensured here too so a fresh profile with no history/
        // bookmarks activity yet still gets a writable directory.
        try? FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let store = PermissionStore(profileDirectory: profileDirectory)
        cache[profile.id] = store
        return store
    }
}
