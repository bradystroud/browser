import Foundation

/// Reads/writes SessionSnapshot as JSON under
/// CommandLineArgs.sessionAndProfilesMetadataDirectory() -- normally
/// `~/Library/Application Support/Browser/session.json`, but an explicit
/// `--profiles-root <path>` launch fully redirects this alongside
/// ProfileManager's profiles.json (browser-1rp -- previously both were
/// hardcoded regardless of that flag, so every "isolated" test launch
/// actually read and wrote Brady's real session/profile state).
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
        let dir = URL(fileURLWithPath: CommandLineArgs.sessionAndProfilesMetadataDirectory())
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
