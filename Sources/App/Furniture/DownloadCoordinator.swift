import Foundation

/// Posted (object: the profile id whose downloads changed) whenever a
/// download is created or updated, so DownloadsWindowController can refresh
/// without polling.
extension Notification.Name {
    static let downloadsDidChange = Notification.Name("Browser.downloadsDidChange")
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

    private init() {}

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
        NotificationCenter.default.post(name: .downloadsDidChange, object: profile.id)
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
