import Foundation
@testable import WebKitAdapter

/// Records every EngineTabDelegate callback, in arrival order, as a short
/// "name:detail" string, so ordering assertions read like the callback log
/// the CEF adapter would produce. Hooks let a test answer page messages and
/// watch downloads.
final class RecordingTabDelegate: EngineTabDelegate {
    private(set) var events: [String] = []

    struct Download {
        var url: String
        var suggestedName: String
        var destinationPath: String
        var isComplete = false
        var isCancelled = false
        var isInterrupted = false
    }
    private(set) var downloads: [Int64: Download] = [:]
    private(set) var findResults: [(count: Int, ordinal: Int, isFinal: Bool)] = []
    private(set) var pageMessages: [(request: String, requestId: Int64, source: PageMessageSource)] = []

    /// Called for each page message; the test answers (or deliberately
    /// doesn't) through EngineTab.respondToPageMessage.
    var onPageMessage: ((String, Int64) -> Void)?

    func events(named name: String) -> [String] {
        events.filter { $0 == name || $0.hasPrefix(name + ":") }
    }

    func firstIndex(of name: String) -> Int? {
        events.firstIndex { $0 == name || $0.hasPrefix(name + ":") }
    }

    func lastIndex(of name: String) -> Int? {
        events.lastIndex { $0 == name || $0.hasPrefix(name + ":") }
    }

    func reset() {
        events.removeAll()
        findResults.removeAll()
    }

    /// Popups must be adopted synchronously; holding them keeps them alive.
    var popups: [EnginePopupTab] = []

    func engineTabDidChangeTitle(_ title: String) { events.append("title:\(title)") }
    func engineTabDidChangeURL(_ url: String) { events.append("url:\(url)") }
    func engineTabDidChangeFaviconURL(_ faviconURL: String?) { events.append("favicon:\(faviconURL ?? "nil")") }
    func engineTabDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        events.append("loading:\(isLoading)")
    }
    func engineTabWillStartMainFrameNavigation(_ url: String) { events.append("willStart:\(url)") }
    func engineTabDidUpdateLoadingProgress(_ progress: Double) { events.append("progress:\(progress)") }
    func engineTabDidCommitNavigation(_ url: String) { events.append("commit:\(url)") }
    func engineTabDidStartMainFrameLoad() { events.append("didStartLoad") }
    func engineTabDidCreatePopup(_ popup: EnginePopupTab, disposition: EngineWindowOpenDisposition) {
        events.append("popup")
        popups.append(popup)
    }
    func engineTabDidRequestClose() { events.append("requestClose") }

    func engineTabDidBeginDownload(id: Int64, url: String, suggestedName: String, destinationPath: String) {
        events.append("downloadBegin:\(suggestedName)")
        downloads[id] = Download(url: url, suggestedName: suggestedName, destinationPath: destinationPath)
    }
    func engineTabDidUpdateDownload(id: Int64, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCancelled: Bool, isInterrupted: Bool) {
        downloads[id]?.isComplete = isComplete
        downloads[id]?.isCancelled = isCancelled
        downloads[id]?.isInterrupted = isInterrupted
        if isComplete || isCancelled || isInterrupted { events.append("downloadEnd:\(id)") }
    }

    func engineTabDidRequestPermission(_ kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        events.append("permission:\(requestingOrigin)")
        decision(false)
    }
    func engineTabDidDismissPermissionRequest(_ promptId: UInt64) {}

    func engineTabDidUpdateFindResult(matchCount: Int, activeMatchOrdinal: Int, isFinalUpdate: Bool) {
        findResults.append((matchCount, activeMatchOrdinal, isFinalUpdate))
    }

    func engineTabDidReceivePageMessage(_ request: String, requestId: Int64, source: PageMessageSource) {
        pageMessages.append((request, requestId, source))
        onPageMessage?(request, requestId)
    }

    func engineTabDidRequestVisualLookUp(imageURL: String, pageURL: String) {}
    func engineTabDidRequestViewSource(pageURL: String) {}
    func engineTabDidRequestCopyImage(imageURL: String, pageURL: String) {}
    func engineTabDidRequestCopyImageLink(imageURL: String) {}
    func engineTabDidRequestDownloadImage(imageURL: String) {}
    func engineTabDidRequestNewTab(url: String, disposition: EngineWindowOpenDisposition) { events.append("newTab:\(url)") }
    func engineTabDidBlockRequest(trackerDomain: String, pageHost: String) { events.append("blocked:\(trackerDomain)") }

    /// Run inside engineTabDevToolsDidOpen, as the app's dock controller
    /// claims an open it did not ask for.
    var onDevToolsOpen: (() -> Void)?
    func engineTabDevToolsDidOpen() {
        events.append("devToolsOpen")
        onDevToolsOpen?()
    }
    func engineTabDevToolsDidClose() { events.append("devToolsClose") }
    func engineTabDevToolsDidRequestDockSide(_ side: DevToolsDockSide) { events.append("devToolsDockSide:\(side.rawValue)") }
}
