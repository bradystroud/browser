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
/// per-callback local scope it's created in.
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

    /// Must run once a download reaches a terminal state. An
    /// ObjectIdentifier is only unique among *live* objects, so a stale
    /// entry would hand a later WKDownload allocated at the same address the
    /// old id -- which DownloadCoordinator reads as a retry and rewinds the
    /// old row instead of recording a new download.
    static func forget(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        ids.removeValue(forKey: key)
        progressObservations.removeValue(forKey: key)
    }
}

/// The download-policy and destination rules the CEF engine gets from
/// Chromium and BRWClientHandler, reproduced for WebKit.
enum WebKitDownloadPolicy {
    /// Whether a navigation response should become a download instead of
    /// being rendered: an explicit `Content-Disposition: attachment` in any
    /// frame (the hidden-iframe download pattern depends on subframes), or a
    /// main-frame MIME type WebKit cannot display.
    static func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
        if isAttachment(navigationResponse.response) { return true }
        return navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType
    }

    /// Chromium's reading of the disposition type (net::HttpContentDisposition):
    /// "inline", an empty type, or a header that opens straight into a
    /// parameter (`filename=x`) render inline; any other type, including an
    /// unknown one, is an attachment, as RFC 6266 section 4.2 requires.
    static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        let type = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return !type.isEmpty && !type.contains("=") && type != "inline"
    }

    /// Same rule as UniqueDownloadPath in BRWClientHandler.mm: "name.ext",
    /// then "name (1).ext", "name (2).ext", ... WebKit refuses to write over
    /// an existing file and fails the download instead, so without this a
    /// repeat download of one filename would always fail.
    static func uniqueDestination(in directory: URL, suggestedName: String, isTaken: (URL) -> Bool) -> URL {
        var candidate = directory.appendingPathComponent(suggestedName)
        if !isTaken(candidate) { return candidate }
        let name = suggestedName as NSString
        let ext = name.pathExtension
        let base = name.deletingPathExtension
        for i in 1..<10000 {
            let attempt = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = directory.appendingPathComponent(attempt)
            if !isTaken(candidate) { return candidate }
        }
        return candidate  // Effectively unreachable; last attempt wins over an infinite loop.
    }

    /// Destinations handed to downloads still in flight. WebKit writes to a
    /// temporary file and only moves it into place on completion, so two
    /// concurrent downloads of one name would both find the destination free
    /// and the second would fail at the move. Chromium avoids that by
    /// creating the file up front; reserving the path gives the same result.
    struct InFlight {
        let destination: URL
        let sourceURL: URL?
        let originURL: URL?
    }

    private static var reserved: [ObjectIdentifier: InFlight] = [:]

    static func reserveDestination(for download: WKDownload, in directory: URL, suggestedName: String, sourceURL: URL?, originURL: URL?) -> URL {
        let inFlight = Set(reserved.values.map(\.destination.path))
        let destination = uniqueDestination(in: directory, suggestedName: suggestedName) { url in
            inFlight.contains(url.path) || FileManager.default.fileExists(atPath: url.path)
        }
        reserved[ObjectIdentifier(download)] = InFlight(destination: destination, sourceURL: sourceURL, originURL: originURL)
        return destination
    }

    @discardableResult
    static func releaseDestination(for download: WKDownload) -> InFlight? {
        reserved.removeValue(forKey: ObjectIdentifier(download))
    }

    /// WebKit quarantines a finished download but types it "Sandboxed",
    /// and writes no Spotlight "Where from" at all.
    /// Chromium (components/services/quarantine/quarantine_mac.mm) writes
    /// both on CEF; this reproduces them, merging into WebKit's quarantine
    /// record rather than replacing it.
    static func annotateDownloadedFile(_ entry: InFlight) {
        annotateQuarantine(entry)
        setWhereFroms(entry)
    }

    /// Finder's Get Info "Where from": a binary-plist array of the file's
    /// URL then its referrer, in the xattr Spotlight reads.
    private static func setWhereFroms(_ entry: InFlight) {
        let froms = [entry.sourceURL, entry.originURL].compactMap { $0?.absoluteString }
        guard !froms.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: froms, format: .binary, options: 0) else { return }
        let result = data.withUnsafeBytes { bytes in
            setxattr(entry.destination.path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 {
            NSLog("Browser: could not record Where-from on %@ (errno %d)", entry.destination.path, errno)
        }
    }

    private static func annotateQuarantine(_ entry: InFlight) {
        var url = entry.destination
        var properties = ((try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties) ?? [:]
        func setIfMissing(_ key: CFString, _ value: Any?) {
            guard let value, properties[key as String] == nil else { return }
            properties[key as String] = value
        }
        // WebKit's record says "Sandboxed", which describes its own network
        // process rather than where the file came from.
        if properties[kLSQuarantineTypeKey as String] as? String == "LSQuarantineTypeSandboxed" {
            properties.removeValue(forKey: kLSQuarantineTypeKey as String)
        }
        setIfMissing(kLSQuarantineTypeKey, kLSQuarantineTypeWebDownload as String)
        // URL values, as Chromium passes them. Current macOS no longer keeps
        // these in the quarantine event database for any browser; they are
        // set for parity; setWhereFroms is what the user actually sees.
        setIfMissing(kLSQuarantineDataURLKey, entry.sourceURL)
        setIfMissing(kLSQuarantineOriginURLKey, entry.originURL)
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try url.setResourceValues(values)
        } catch {
            NSLog("Browser: could not annotate quarantine on %@: %@", url.path, error.localizedDescription)
        }
    }

    static func downloadsDirectory() -> URL {
        let configured = WebKitEngine.downloadDirectory
        return configured.isEmpty
            ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
            : URL(fileURLWithPath: configured)
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
        let downloadsURL = WebKitDownloadPolicy.downloadsDirectory()
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        // The page the download came from, for the quarantine record: the
        // request's Referer when there is one, else the page this tab shows.
        let referrer = download.originalRequest?.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:))
        let origin = (referrer ?? webView.url).flatMap { $0 == response.url ? nil : $0 }
        let destination = WebKitDownloadPolicy.reserveDestination(for: download, in: downloadsURL, suggestedName: suggestedFilename, sourceURL: response.url, originURL: origin)
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
        DownloadIdentifiers.forget(download)
        if let entry = WebKitDownloadPolicy.releaseDestination(for: download) {
            WebKitDownloadPolicy.annotateDownloadedFile(entry)
        }
        delegate?.engineTabDidUpdateDownload(id: id, receivedBytes: bytes, totalBytes: bytes, isComplete: true, isCancelled: false, isInterrupted: false)
    }

    /// `resumeData` is dropped: CEF has no resume surface in EngineTab either
    /// (Chromium retries internally), and there is no UI to resume from.
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = DownloadIdentifiers.id(for: download)
        let bytes = download.progress.completedUnitCount
        let total = download.progress.totalUnitCount
        DownloadIdentifiers.forget(download)
        WebKitDownloadPolicy.releaseDestination(for: download)
        let nsError = error as NSError
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        if !cancelled {
            NSLog("Browser: WebKit download %lld failed: %@", id, nsError.localizedDescription)
        }
        delegate?.engineTabDidUpdateDownload(id: id, receivedBytes: bytes, totalBytes: total, isComplete: false, isCancelled: cancelled, isInterrupted: !cancelled)
    }
}
