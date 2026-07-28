import AppKit

/// The only concrete BrowserEngine today, and the only file in Sources/App
/// (besides BrowserEngine.swift's doc comments, and the necessarily
/// target-wide Swift bridging header / Info.plist / CMakeLists.txt build
/// config -- see docs/ai-tasks/browser-n50-notes.md) that references any
/// BRW* bridge symbol. Everything CEF-specific is confined to this file:
/// CEFEngine adapts BRWEngine + BRWApplication, CEFTab adapts BRWBrowser.
/// Zero behavior change from the pre-refactor direct BRW* usage -- this is
/// a straight pass-through.
enum CEFEngine: BrowserEngine {
    static func bootstrapApplication() {
        BRWApplication.bootstrap()
    }

    static func initialize(profilesRootPath: String) -> Bool {
        let ok = BRWEngine.initialize(withProfilesRootPath: profilesRootPath)
        if ok {
            // Must start only once the engine is up: the very first
            // snapshot push (loading the starter list + every existing
            // profile's BlockingSettings) needs ProfileManager/CEF ready,
            // and every browser created from here on needs a snapshot
            // already published before its first request -- see
            // ContentBlockerCoordinator's doc comment (browser-12m.5.1).
            ContentBlockerCoordinator.shared.start()
            // Same requirement, independent feature (browser-12m.6) -- see
            // ThreatListCoordinator's doc comment.
            ThreatListCoordinator.shared.start()
            // browser-7jz.3 -- registers with PageMessageDispatcher and
            // UNUserNotificationCenter before any tab can navigate.
            WebPushCoordinator.shared.activate()
        }
        return ok
    }

    static func createTab(profileName: String, hostView: NSView, initialURL: String) -> EngineTab {
        CEFTab(profileName: profileName, hostView: hostView, initialURL: initialURL)
    }

    static func createPrivateTab(hostView: NSView, initialURL: String) -> EngineTab {
        CEFTab(privateHostView: hostView, initialURL: initialURL)
    }

    static func setWindowCloseHandler(_ handler: @escaping () -> Void) {
        BRWEngine.setWindowCloseHandler(handler)
    }

    static var isTerminating: Bool {
        (NSApp as? BRWApplication)?.isTerminating ?? false
    }
}

/// Wraps a single BRWBrowser, translating its Objective-C BRWBrowserDelegate
/// callbacks into EngineTabDelegate calls -- the only place that translation
/// happens. `private`: nothing outside this file needs the concrete type,
/// only the EngineTab protocol CEFEngine.createTab returns.
private final class CEFTab: NSObject, EngineTab, BRWBrowserDelegate {
    weak var delegate: EngineTabDelegate?
    private let browser: BRWBrowser

    init(profileName: String, hostView: NSView, initialURL: String) {
        browser = BRWBrowser(profileName: profileName, hostView: hostView, initialURL: initialURL)
        super.init()
        browser.delegate = self
    }

    /// Private Browsing (browser-12m.1) -- see BRWBrowser.h's
    /// -initPrivateWithHostView:initialURL: for what makes this different
    /// from the designated initializer above.
    init(privateHostView hostView: NSView, initialURL: String) {
        browser = BRWBrowser(privateWithHostView: hostView, initialURL: initialURL)
        super.init()
        browser.delegate = self
    }

    func loadURL(_ url: String) { browser.loadURL(url) }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() { browser.reload() }
    func close() { browser.close() }
    func showDevTools() { browser.showDevTools() }
    func closeDevTools() { browser.closeDevTools() }
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        browser.setResponsiveDesignMode(width: Int32(width), height: Int32(height), deviceScaleFactor: deviceScaleFactor, mobile: mobile)
    }
    func clearResponsiveDesignMode() { browser.clearResponsiveDesignMode() }
    func setAudioMuted(_ muted: Bool) { browser.setAudioMuted(muted) }
    func isAudioMuted() -> Bool { browser.isAudioMuted() }
    func print() { browser.print() }
    func printToPDF(path: String, completion: @escaping (Bool, String) -> Void) {
        browser.printToPDF(withPath: path, completion: completion)
    }
    func find(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        browser.find(searchText, forward: forward, matchCase: matchCase, findNext: findNext)
    }
    func stopFinding(clearSelection: Bool) {
        browser.stopFinding(clearSelection)
    }
    func executeJavaScript(_ code: String) {
        browser.executeJavaScript(code)
    }
    func getPageSource(completion: @escaping (String?) -> Void) {
        browser.getPageSource(completion: completion)
    }
    func respondToPageMessage(requestId: Int64, success: Bool, response: String) {
        browser.respondToPageMessage(withId: requestId, success: success, response: response)
    }

    // MARK: - BRWBrowserDelegate -> EngineTabDelegate

    func browserDidChangeTitle(_ title: String) {
        delegate?.engineTabDidChangeTitle(title)
    }

    func browserDidChangeURL(_ url: String) {
        delegate?.engineTabDidChangeURL(url)
    }

    func browserDidChangeFaviconURL(_ faviconURL: String?) {
        delegate?.engineTabDidChangeFaviconURL(faviconURL)
    }

    func browserDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        delegate?.engineTabDidChangeLoadingState(isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func browserDidCommitNavigation(_ url: String) {
        delegate?.engineTabDidCommitNavigation(url)
    }

    func browserDidBeginDownload(withId downloadId: Int64, url: String, suggestedName: String, destinationPath: String) {
        delegate?.engineTabDidBeginDownload(id: downloadId, url: url, suggestedName: suggestedName, destinationPath: destinationPath)
    }

    func browserDidUpdateDownload(withId downloadId: Int64, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCancelled: Bool, isInterrupted: Bool) {
        delegate?.engineTabDidUpdateDownload(
            id: downloadId, receivedBytes: receivedBytes, totalBytes: totalBytes,
            isComplete: isComplete, isCancelled: isCancelled, isInterrupted: isInterrupted)
    }

    func browserDidRequestPermission(_ kinds: BRWPermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        var engineKinds: EnginePermissionKind = []
        if kinds.contains(.camera) { engineKinds.insert(.camera) }
        if kinds.contains(.microphone) { engineKinds.insert(.microphone) }
        if kinds.contains(.geolocation) { engineKinds.insert(.geolocation) }
        if kinds.contains(.notifications) { engineKinds.insert(.notifications) }
        delegate?.engineTabDidRequestPermission(engineKinds, promptId: promptId, requestingOrigin: requestingOrigin, decision: decision)
    }

    func browserDidDismissPermissionRequest(_ promptId: UInt64) {
        delegate?.engineTabDidDismissPermissionRequest(promptId)
    }

    func browserDidUpdateFindResult(withMatchCount matchCount: Int32, activeMatchOrdinal: Int32, finalUpdate isFinalUpdate: Bool) {
        delegate?.engineTabDidUpdateFindResult(
            matchCount: Int(matchCount), activeMatchOrdinal: Int(activeMatchOrdinal), isFinalUpdate: isFinalUpdate)
    }

    func browserDidReceivePageMessage(_ request: String, requestId: Int64) {
        delegate?.engineTabDidReceivePageMessage(request, requestId: requestId)
    }

    func browserDidStartMainFrameLoad() {
        delegate?.engineTabDidStartMainFrameLoad()
    }
}

/// The engine the app builds against today. main.swift and AppDelegate
/// reference this type name (never a BRW* symbol) to bootstrap and
/// initialize it -- see BrowserEngine's doc comment for why a protocol with
/// static requirements, conformed to by exactly one type at a time, is the
/// right shape here.
typealias ActiveEngine = CEFEngine
