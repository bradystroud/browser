import Foundation

/// Persisted session state -- every open window across every profile, saved
/// as a single JSON file (not one file per profile) so a relaunch can
/// recreate the whole desktop in one read. See SessionStore for
/// load/save/debounce and WindowManager for what triggers a save and how
/// restore recreates windows/tabs.
struct SessionSnapshot: Codable {
    struct WindowFrame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Tab: Codable {
        let url: String
        let title: String
        /// Absent in a session.json written before pinned tabs (browser-
        /// rhi.2) shipped -- decodeIfPresent below defaults a missing key to
        /// false rather than failing to decode the whole file, so an old
        /// session still loads (every tab just comes back unpinned).
        let isPinned: Bool
        /// Absent (nil) for an ungrouped tab, or one from a session.json
        /// written before tab groups (browser-rhi.1) shipped --
        /// decodeIfPresent already tolerates a missing key for an Optional
        /// with no extra fallback needed, unlike isPinned's Bool above
        /// (which has no "absent" state of its own).
        let groupId: UUID?

        init(url: String, title: String, isPinned: Bool = false, groupId: UUID? = nil) {
            self.url = url
            self.title = title
            self.isPinned = isPinned
            self.groupId = groupId
        }

        private enum CodingKeys: String, CodingKey {
            case url, title, isPinned, groupId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(String.self, forKey: .url)
            title = try container.decode(String.self, forKey: .title)
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            groupId = try container.decodeIfPresent(UUID.self, forKey: .groupId)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(url, forKey: .url)
            try container.encode(title, forKey: .title)
            try container.encode(isPinned, forKey: .isPinned)
            try container.encodeIfPresent(groupId, forKey: .groupId)
        }
    }

    /// A persisted tab group -- see TabGroup for the live in-memory type this
    /// mirrors. A brand-new type (no pre-existing session.json ever had
    /// groups), so plain synthesized Codable is fine here; the tolerance
    /// concern is entirely on Window.groups below (an old file has no
    /// `groups` key at all) and Tab.groupId above.
    struct Group: Codable {
        let id: UUID
        let name: String
        let colorHex: String
        let isCollapsed: Bool
    }

    struct Window: Codable {
        let profileId: String
        let frame: WindowFrame?
        let tabs: [Tab]
        let activeTabIndex: Int
        /// Absent in a session.json written before tab groups (browser-
        /// rhi.1) shipped -- nil (not an empty array) is the natural
        /// "missing key" decode for an Optional property under synthesized
        /// Codable, the same mechanism `frame` above already relies on. Read
        /// as `groups ?? []` at every use site (see WindowManager).
        let groups: [Group]?
    }

    var windows: [Window]

    /// Restoring more tabs than this in one window is treated as a
    /// runaway/stale snapshot rather than a real browsing session --
    /// truncated at restore time (see WindowManager.restoreSession), not
    /// refused outright, so the user still gets *a* restored window instead
    /// of nothing.
    static let maxTabsPerWindow = 50
}

/// Reads/writes SessionSnapshot as JSON at
/// ~/Library/Application Support/Browser/session.json (same fixed location
/// regardless of `--profiles-root`, matching ProfileManager's profiles.json
/// precedent -- see CommandLineArgs.profilesRootPath's doc comment for why
/// that override exists and what it does and doesn't cover).
///
/// Saves are debounced (see scheduleSave) for the high-frequency triggers
/// (typing/navigating, dragging a window) -- WindowManager.
/// closeAllWindowsForShutdown calls saveNow directly instead, since quitting
/// can't wait out a debounce timer.
///
/// No separate crash/stale-session sentinel file: because every meaningful
/// change (tab open/close, committed navigation, window move/resize) already
/// schedules a save independent of a clean quit, the on-disk file is always
/// either absent or a reasonably recent snapshot -- there's no distinct
/// "stale from a crash" state to detect beyond "how recent is this," which
/// isn't gated on here. A crash between the last debounced save and the
/// crash itself just means restoring from a few seconds before the crash,
/// which is the same "still restore" outcome asked for.
final class SessionStore {
    static let shared = SessionStore()

    private let fileURL: URL
    private let debounceInterval: TimeInterval = 1.0
    private var pendingSaveWorkItem: DispatchWorkItem?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Browser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("session.json")
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Debounced: `snapshotProvider` is evaluated once the debounce window
    /// elapses (not eagerly), so a burst of calls (e.g. dragging a window,
    /// or several tabs opening in quick succession) only actually
    /// snapshots+writes once, with whatever the state is by the time it
    /// finally fires. Must be called on the main thread (the snapshot itself
    /// reads AppKit window/tab state, which is main-thread-only).
    func scheduleSave(_ snapshotProvider: @escaping () -> SessionSnapshot) {
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveNow(snapshotProvider())
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Immediate, synchronous save -- used at quit time, where there's no
    /// time to wait out scheduleSave's debounce. Cancels any pending
    /// debounced save so it doesn't fire later with stale (post-quit) state.
    func saveNow(_ snapshot: SessionSnapshot) {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
