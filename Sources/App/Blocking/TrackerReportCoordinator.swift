import AppKit

/// Connects the in-app recorder to the per-profile store, and owns the one
/// `TrackerReportStore` per profile (browser-e7r).
///
/// Deliberately thin: the recorder decides what is worth recording and when
/// to flush, the store decides how it is written and pruned, and this only
/// knows which profile's store a flushed batch belongs to. That split is
/// what lets the interesting half of each be tested without the other --
/// the store has SwiftPM tests in BrowserCore, and the recorder has no
/// SQLite in it at all.
///
/// Stores are opened lazily, keyed by `Profile.id`, mirroring
/// ProfileDataStoreManager. A profile that never has a tracker blocked never
/// gets a privacy-report.db file at all.
final class TrackerReportCoordinator: NSObject, TrackerReportSink {
    static let shared = TrackerReportCoordinator()

    private var stores: [String: TrackerReportStore] = [:]

    private override init() {
        super.init()
    }

    /// Call once at launch, after the engine is up. Registers as the
    /// recorder's sink and arranges the flush that matters most -- the one
    /// at quit, without which the last few seconds of every session are
    /// silently lost.
    func start() {
        TrackerReportRecorder.shared.sink = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func applicationWillTerminate() {
        TrackerReportRecorder.shared.flush()
    }

    /// The report for one profile, or nil if its store cannot be opened --
    /// a report is a nice-to-have, so a profile directory that refuses to
    /// give one up shows an empty report rather than failing anything the
    /// user was actually doing.
    func store(for profile: Profile) -> TrackerReportStore? {
        if let existing = stores[profile.id] {
            return existing
        }
        let directory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profile.id))
        guard let store = try? TrackerReportStore(profileDirectory: directory) else { return nil }
        stores[profile.id] = store
        return store
    }

    /// Clears one profile's report. Wired to the Privacy pane's own button;
    /// separate from clearing history, because a user who wants to forget
    /// where they went and a user who wants to forget who followed them
    /// there are asking different questions.
    func clearReport(for profile: Profile) {
        try? store(for: profile)?.clear()
    }

    // MARK: - TrackerReportSink

    func addTrackerBlocks(_ counts: [TrackerBlockTally: Int], forProfileId profileId: String) {
        // A batch for a profile that has since been deleted is dropped
        // rather than recreating its directory to write a report nobody can
        // ever open.
        guard let profile = ProfileManager.shared.profile(id: profileId),
              let store = store(for: profile)
        else { return }
        try? store.addTallies(counts)
    }
}
