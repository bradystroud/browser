import AppKit
import WebKit

/// One process-wide counter for synthesizing EngineTab's Int64 download ids
/// -- WKDownload itself has no numeric identifier (see WKDownload.h), only
/// object identity, so this maps that identity to a stable id for the
/// engine-agnostic delegate contract. Also holds the KVO observation for
/// that download's real byte-progress reporting (see WKDownload's
/// `NSProgressReporting` conformance -- `.progress.completedUnitCount`/
/// `.totalUnitCount` are genuine, live-updating values, unlike the
/// once-at-start/once-at-end-only 0/0 a naive port of this delegate would
/// report) -- keyed the same way so the observation outlives the
/// per-callback local scope it's created in but is released once the
/// download itself is deallocated.
private enum DownloadIdentifiers {
    private static var nextId: Int64 = 1
    private static var ids: [ObjectIdentifier: Int64] = [:]
    private static var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    static func id(for download: WKDownload) -> Int64 {
        let key = ObjectIdentifier(download)
        if let existing = ids[key] { return existing }
        let id = nextId
        nextId += 1
        ids[key] = id
        return id
    }

    static func observeProgress(of download: WKDownload, id: Int64, onUpdate: @escaping (Int64, Int64) -> Void) {
        let key = ObjectIdentifier(download)
        progressObservations[key] = download.progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
            onUpdate(progress.completedUnitCount, progress.totalUnitCount)
        }
    }

    static func stopObserving(_ download: WKDownload) {
        progressObservations.removeValue(forKey: ObjectIdentifier(download))
    }
}

extension WebKitTab: WKDownloadDelegate {
    /// WKWebView's `startDownload(using:completionHandler:)` is the real
    /// equivalent of CefBrowserHost::StartDownload, and lands in the same
    /// WKDownloadDelegate callbacks below that a page-initiated download
    /// does -- so, as on CEF, a "Download Image" started here would appear
    /// in DownloadStore alongside everything else. (Moot in practice: this
    /// engine can't add the context-menu item that triggers it, see
    /// setVisualLookUpAvailable's own comment.)
    func startDownload(url: String) {
        guard let parsed = URL(string: url) else {
            NSLog("Browser: WebKit startDownload got an unparseable URL: %@", url)
            return
        }
        webView.startDownload(using: URLRequest(url: parsed)) { download in
            download.delegate = self
        }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let configured = WebKitEngine.downloadDirectory
        let downloadsURL = configured.isEmpty
            ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
            : URL(fileURLWithPath: configured)
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        let destination = downloadsURL.appendingPathComponent(suggestedFilename)
        let id = DownloadIdentifiers.id(for: download)
        delegate?.engineTabDidBeginDownload(id: id, url: response.url?.absoluteString ?? "", suggestedName: suggestedFilename, destinationPath: destination.path)
        // WKDownload conforms to NSProgressReporting (see WKDownload.h) --
        // .progress.completedUnitCount/.totalUnitCount are real, live-
        // updating KVO values, genuinely equivalent to CEF's repeated
        // -browserDidUpdateDownloadWithId:receivedBytes:totalBytes:...,
        // unlike this delegate's other two callbacks (which only fire once
        // each, at completion/failure).
        DownloadIdentifiers.observeProgress(of: download, id: id) { [weak self] completed, total in
            self?.delegate?.engineTabDidUpdateDownload(id: id, receivedBytes: completed, totalBytes: total, isComplete: false, isCancelled: false, isInterrupted: false)
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = DownloadIdentifiers.id(for: download)
        let bytes = download.progress.completedUnitCount
        DownloadIdentifiers.stopObserving(download)
        delegate?.engineTabDidUpdateDownload(id: id, receivedBytes: bytes, totalBytes: bytes, isComplete: true, isCancelled: false, isInterrupted: false)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = DownloadIdentifiers.id(for: download)
        let bytes = download.progress.completedUnitCount
        DownloadIdentifiers.stopObserving(download)
        delegate?.engineTabDidUpdateDownload(id: id, receivedBytes: bytes, totalBytes: download.progress.totalUnitCount, isComplete: false, isCancelled: false, isInterrupted: true)
    }
}
