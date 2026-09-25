import Foundation

/// Posted (object: the profile id whose downloads changed) whenever a
/// download is created, changes state, or has made progress -- the last at
/// most once per DownloadCoordinator.progressPersistInterval per download --
/// so DownloadsWindowController can refresh without polling.
extension Notification.Name {
    static let downloadsDidChange = Notification.Name("Browser.downloadsDidChange")
    /// Posted (object: the profile id) only when a download *begins*, not on
    /// every progress tick. DownloadsToolbarController auto-presents its
    /// popover on this and would otherwise have to diff successive
    /// .downloadsDidChange payloads to work out whether anything was actually
    /// new -- a download that merely progressed must not re-open a popover the
    /// user just dismissed.
    static let downloadDidStart = Notification.Name("Browser.downloadDidStart")
}

/// Bridges CEF's per-download lifecycle (BRWClientHandler's OnBeforeDownload/
/// OnDownloadUpdated, forwarded via Tab -> BrowserWindowController) to
/// BrowserCore's DownloadStore. CEF's download ids (CefDownloadItem::GetId())
/// are documented as globally unique for the process, so one flat mapping
/// here (rather than one per profile) is enough to correlate a later
/// -didUpdateDownload call back to the DB row -didBeginDownload created.
final class DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private struct Entry {
        let profileId: String
        let rowId: Int64
    }

    struct Progress: Equatable {
        let receivedBytes: Int64
        let totalBytes: Int64
    }

    /// The engine reports progress many times a second, far more often than
    /// a SQLite write plus a notification that rebuilds every observing view
    /// is worth. Progress between persists lives only in liveProgressByRowId;
    /// state changes are always written at once, since those are what must
    /// survive a crash and what the UI must never show late.
    static let progressPersistInterval: TimeInterval = 1

    private var rowsByDownloadId: [Int64: Entry] = [:]
    private var liveProgressByRowId: [Int64: Progress] = [:]
    private var lastPersistByRowId: [Int64: Date] = [:]

    /// DownloadStore rows created during *this* run of the app. The store
    /// itself persists across launches (that's what the ⌘⇧J window shows),
    /// but the toolbar popover deliberately lists only the current session,
    /// which is what a browser's download button conventionally means -- and
    /// is what makes "it popped up, and there's the file I just grabbed"
    /// true rather than "here are 200 files, one of which is new."
    private var startedRowIds: Set<Int64> = []

    private init() {}

    /// Whether `rowId` was started in this session -- the filter behind the
    /// popover's list. Row ids come from SQLite's own autoincrement, so this
    /// can't collide with a previous run's.
    func isFromThisSession(rowId: Int64) -> Bool {
        startedRowIds.contains(rowId)
    }

    var hasSessionDownloads: Bool { !startedRowIds.isEmpty }

    /// The newest progress the engine has reported for an unfinished
    /// download, which can be ahead of its DownloadStore row by up to
    /// progressPersistInterval.
    func liveProgress(rowId: Int64) -> Progress? {
        liveProgressByRowId[rowId]
    }

    /// Records the start of a download -- or, when the engine is retrying one
    /// it already reported, rewinds the row that download already has.
    ///
    /// A retry is not a new download. Chromium restarts an interrupted
    /// transfer by re-entering OnBeforeDownload with the *same*
    /// CefDownloadItem, so `info.downloadId` is unchanged (measured: one
    /// interrupted transfer re-entered five times, all reporting id 1).
    /// Inserting a row per call therefore produced six rows for one file, five
    /// of them stranded at "downloading" forever, because progress updates
    /// only ever reach the row this mapping currently points at (browser-s24).
    func beginDownload(profile: Profile, info: TabDownloadStart) {
        let store = ProfileDataStoreManager.shared.stores(for: profile).downloads
        if let existing = rowsByDownloadId[info.downloadId], existing.profileId == profile.id {
            try? store.restart(id: existing.rowId, destinationPath: info.destinationPath)
            forgetProgress(rowId: existing.rowId)
            // .downloadsDidChange, but deliberately not .downloadDidStart: a
            // retry must not re-present the toolbar popover the user may have
            // just dismissed (five times over, for the failure above).
            NotificationCenter.default.post(name: .downloadsDidChange, object: profile.id)
            return
        }
        guard let rowId = try? store.create(
            url: info.url,
            suggestedName: info.suggestedName,
            destinationPath: info.destinationPath
        ) else {
            NSLog("Browser: failed to record download start for %@", info.url)
            return
        }
        rowsByDownloadId[info.downloadId] = Entry(profileId: profile.id, rowId: rowId)
        startedRowIds.insert(rowId)
        NotificationCenter.default.post(name: .downloadsDidChange, object: profile.id)
        NotificationCenter.default.post(name: .downloadDidStart, object: profile.id)
    }

    func updateDownload(profile: Profile, info: TabDownloadUpdate) {
        guard let entry = rowsByDownloadId[info.downloadId] else {
            // Extremely unlikely (would mean an update arrived with no
            // matching begin), but not worth crashing over -- just drop it.
            return
        }
        let store = ProfileDataStoreManager.shared.stores(for: profile).downloads
        let terminalState: DownloadState?
        if info.isComplete {
            terminalState = .completed
        } else if info.isCancelled {
            terminalState = .cancelled
        } else if info.isInterrupted {
            terminalState = .interrupted
        } else {
            terminalState = nil
        }

        if let terminalState {
            // The final byte counts may not have been persisted yet.
            try? store.updateProgress(id: entry.rowId, receivedBytes: info.receivedBytes, totalBytes: info.totalBytes)
            try? store.updateState(id: entry.rowId, state: terminalState)
            forgetProgress(rowId: entry.rowId)
        } else {
            let progress = Progress(receivedBytes: info.receivedBytes, totalBytes: info.totalBytes)
            guard progress != liveProgressByRowId[entry.rowId] else { return }
            liveProgressByRowId[entry.rowId] = progress
            let now = Date()
            if let last = lastPersistByRowId[entry.rowId],
               now.timeIntervalSince(last) < Self.progressPersistInterval {
                return
            }
            lastPersistByRowId[entry.rowId] = now
            try? store.updateProgress(id: entry.rowId, receivedBytes: progress.receivedBytes, totalBytes: progress.totalBytes)
        }
        NotificationCenter.default.post(name: .downloadsDidChange, object: entry.profileId)
    }

    private func forgetProgress(rowId: Int64) {
        liveProgressByRowId.removeValue(forKey: rowId)
        lastPersistByRowId.removeValue(forKey: rowId)
    }
}
