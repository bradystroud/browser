import Foundation

/// Posted (object: the profile id whose downloads changed) whenever a
/// download is created or updated, so DownloadsWindowController can refresh
/// without polling.
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

    private var rowsByDownloadId: [Int64: Entry] = [:]

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

    func beginDownload(profile: Profile, info: TabDownloadStart) {
        let store = ProfileDataStoreManager.shared.stores(for: profile).downloads
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
        if info.isComplete {
            try? store.updateState(id: entry.rowId, state: .completed)
        } else if info.isCancelled {
            try? store.updateState(id: entry.rowId, state: .cancelled)
        } else if info.isInterrupted {
            try? store.updateState(id: entry.rowId, state: .interrupted)
        } else {
            try? store.updateProgress(id: entry.rowId, receivedBytes: info.receivedBytes, totalBytes: info.totalBytes)
        }
        NotificationCenter.default.post(name: .downloadsDidChange, object: entry.profileId)
    }
}
