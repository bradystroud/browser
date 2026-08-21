import Foundation

/// One remembered decision, exposed read-only for the Settings Privacy
/// pane's per-site permission list (browser-12m.2.1) -- origin, which of
/// the four supported kinds, and whether it was allowed or denied. `kind`
/// is the same raw string PermissionStore.keys(for:) already uses
/// internally ("camera"/"microphone"/"geolocation"/"notifications").
struct PermissionDecisionEntry: Equatable {
    let origin: String
    let kind: String
    let allowed: Bool
}

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
        // Normalized on the way in as well as on the way through, so a file
        // written before this normalization existed keeps working: its keys
        // are folded to the same shape here, and the next save writes them
        // back in that shape. Sorted first only so a file that somehow holds
        // two spellings of one origin merges the same way every launch
        // rather than in whatever order the dictionary happens to iterate.
        decisions = [:]
        for origin in decoded.keys.sorted() {
            decisions[Self.normalized(origin)] = (decisions[Self.normalized(origin)] ?? [:])
                .merging(decoded[origin] ?? [:]) { _, new in new }
        }
    }

    /// One spelling per origin. Chromium hands permission requests to this
    /// app as a GURL spec ("https://example.com/"), while anything building
    /// an origin from a URL's own components naturally writes it without the
    /// trailing slash -- two keys, one site, and a remembered "allow" that
    /// silently stops being found. Case follows: hosts are case-insensitive.
    private static func normalized(_ origin: String) -> String {
        let lowered = origin.lowercased()
        return lowered.hasSuffix("/") ? String(lowered.dropLast()) : lowered
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
        guard !keys.isEmpty, let originDecisions = decisions[Self.normalized(origin)] else { return nil }
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
        let key = Self.normalized(origin)
        var originDecisions = decisions[key] ?? [:]
        for kindKey in Self.keys(for: kinds) {
            originDecisions[kindKey] = allowed
        }
        decisions[key] = originDecisions
        save()
    }

    /// Clears every remembered decision for every origin in this profile.
    /// Wired to the Privacy pane's "Reset All" button (browser-12m.2.1).
    func resetAll() {
        decisions = [:]
        save()
    }

    /// Every remembered decision across every origin in this profile,
    /// sorted for a stable, scannable list (origin, then kind) -- backs the
    /// Privacy pane's per-site permission table (browser-12m.2.1).
    func allDecisions() -> [PermissionDecisionEntry] {
        var entries: [PermissionDecisionEntry] = []
        for (origin, kinds) in decisions {
            for (kind, allowed) in kinds {
                entries.append(PermissionDecisionEntry(origin: origin, kind: kind, allowed: allowed))
            }
        }
        entries.sort { lhs, rhs in
            if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
            return lhs.kind < rhs.kind
        }
        return entries
    }

    /// Forgets one origin's decision for one specific kind -- e.g. "stop
    /// remembering that example.com was allowed camera access" without
    /// touching its other permissions. Drops the origin's entry entirely
    /// once it has no decisions left, keeping the persisted file tidy.
    func removeDecision(origin: String, kind: String) {
        let key = Self.normalized(origin)
        guard var originDecisions = decisions[key] else { return }
        originDecisions.removeValue(forKey: kind)
        if originDecisions.isEmpty {
            decisions.removeValue(forKey: key)
        } else {
            decisions[key] = originDecisions
        }
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
