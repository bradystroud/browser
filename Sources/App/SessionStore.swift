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
    }

    struct Window: Codable {
        let profileId: String
        let frame: WindowFrame?
        let tabs: [Tab]
        let activeTabIndex: Int
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
