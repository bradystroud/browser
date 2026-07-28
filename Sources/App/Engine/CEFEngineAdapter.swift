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
        BRWEngine.initialize(withProfilesRootPath: profilesRootPath)
    }

    static func createTab(profileName: String, hostView: NSView, initialURL: String) -> EngineTab {
        CEFTab(profileName: profileName, hostView: hostView, initialURL: initialURL)
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

    func loadURL(_ url: String) { browser.loadURL(url) }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() { browser.reload() }
    func close() { browser.close() }
    func showDevTools() { browser.showDevTools() }
    func closeDevTools() { browser.closeDevTools() }

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
}

/// The engine the app builds against today. main.swift and AppDelegate
/// reference this type name (never a BRW* symbol) to bootstrap and
/// initialize it -- see BrowserEngine's doc comment for why a protocol with
/// static requirements, conformed to by exactly one type at a time, is the
/// right shape here.
typealias ActiveEngine = CEFEngine
