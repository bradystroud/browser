import AppKit

/// The CEF-backed BrowserEngine, and the only file in Sources/App (besides
/// doc comments, and the necessarily target-wide Swift bridging header /
/// Info.plist / CMakeLists.txt build config) that references any BRW*
/// bridge symbol. Everything CEF-specific is confined to this file:
/// CEFEngine adapts BRWEngine + BRWApplication, CEFTab adapts BRWBrowser,
/// each as a straight pass-through.
enum CEFEngine: BrowserEngine {
    static func bootstrapApplication() {
        BRWApplication.bootstrap()
    }

    static var capabilities: EngineCapabilities {
        EngineCapabilities(
            inAppDevTools: true,
            devToolsDocking: false,
            responsiveDesignMode: true,
            perTabCPUUsage: true,
            perTabAudioMute: true,
            customContextMenuItems: true)
    }

    static func initialize(profilesRootPath: String) -> Bool {
        BRWEngine.initialize(withProfilesRootPath: profilesRootPath)
    }

    static func createTab(profileName: String, profileId: String, hostView: NSView, initialURL: String) -> EngineTab {
        CEFTab(profileName: profileName, profileId: profileId, hostView: hostView, initialURL: initialURL)
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

    static func setVisualLookUpAvailable(_ available: Bool) {
        BRWBrowser.setVisualLookUpAvailable(available)
    }

    static func setDownloadDirectory(_ path: String) {
        BRWBrowser.setDownloadDirectory(path)
    }

    static func updateContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings]) {
        var bridgeSettings: [String: BRWProfileBlockingSettings] = [:]
        for (profileName, settings) in profileSettings {
            bridgeSettings[profileName] = BRWProfileBlockingSettings(
                enabled: settings.enabled, allowlistedHosts: settings.allowlistedHosts)
        }
        BRWContentBlocker.update(withBlockedDomains: domains, profileSettings: bridgeSettings)
    }

    static func setThreatInterstitialBuilder(_ builder: @escaping (String, String) -> String) {
        BRWThreatList.setInterstitialPageBuilder(builder)
    }

    static func updateThreatBlocking(domains: [String], profileSettings: [String: EngineProfileThreatSettings]) {
        var bridgeSettings: [String: BRWProfileThreatSettings] = [:]
        for (profileName, settings) in profileSettings {
            bridgeSettings[profileName] = BRWProfileThreatSettings(enabled: settings.enabled)
        }
        BRWThreatList.update(withThreatDomains: domains, profileSettings: bridgeSettings)
    }
}

/// Wraps a single BRWBrowser, translating its Objective-C BRWBrowserDelegate
/// callbacks into EngineTabDelegate calls -- the only place that translation
/// happens. `private`: nothing outside this file needs the concrete type,
/// only the EngineTab protocol CEFEngine.createTab returns.
private final class CEFTab: NSObject, EngineTab, BRWBrowserDelegate {
    weak var delegate: EngineTabDelegate?
    private let browser: BRWBrowser

    init(profileName: String, profileId: String, hostView: NSView, initialURL: String) {
        browser = BRWBrowser(profileName: profileName, profileId: profileId, hostView: hostView, initialURL: initialURL)
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

    // Until the bridge can embed DevTools into a view (docking, panels,
    // picker, inspect-at-point), every entry point opens CEF's own separate
    // DevTools window -- hence devToolsDocking stays false. CEF reports no
    // close from that window, so isDevToolsOpen can go stale when the user
    // closes it themselves.
    private(set) var isDevToolsOpen = false
    func showDevTools(panel: DevToolsPanel, dockSide: DevToolsDockSide, in container: NSView?) {
        browser.showDevTools()
        isDevToolsOpen = true
    }
    func closeDevTools() {
        browser.closeDevTools()
        isDevToolsOpen = false
    }
    func startElementPicker() {}
    func inspectElement(at point: NSPoint) {}
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        browser.setResponsiveDesignMode(width: Int32(width), height: Int32(height), deviceScaleFactor: deviceScaleFactor, mobile: mobile)
    }
    func clearResponsiveDesignMode() { browser.clearResponsiveDesignMode() }
    func cpuUsagePercent() -> Double { browser.cpuUsagePercent() }
    func setAudioMuted(_ muted: Bool) { browser.setAudioMuted(muted) }
    func setZoomLevel(_ level: Double) { browser.setZoomLevel(level) }
    func zoomLevel() -> Double { browser.zoomLevel() }
    func print() { browser.print() }
    func printToPDF(path: String, completion: @escaping (Bool, String) -> Void) {
        browser.printToPDF(withPath: path, completion: completion)
    }
    func downloadImage(url: String, completion: @escaping (Data?, Int) -> Void) {
        browser.downloadImage(atURL: url) { pngData, httpStatusCode in
            completion(pngData, httpStatusCode)
        }
    }
    func startDownload(url: String) {
        browser.startDownload(forURL: url)
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

    func browserWillStartMainFrameNavigation(to url: String) {
        delegate?.engineTabWillStartMainFrameNavigation(url)
    }

    func browserDidUpdateLoadingProgress(_ progress: Double) {
        delegate?.engineTabDidUpdateLoadingProgress(progress)
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

    func browserDidRequestVisualLookUp(forImageURL imageURL: String, pageURL: String) {
        delegate?.engineTabDidRequestVisualLookUp(imageURL: imageURL, pageURL: pageURL)
    }

    func browserDidRequestViewSource(forPageURL pageURL: String) {
        delegate?.engineTabDidRequestViewSource(pageURL: pageURL)
    }

    func browserDidRequestCopyImage(forImageURL imageURL: String, pageURL: String) {
        delegate?.engineTabDidRequestCopyImage(imageURL: imageURL, pageURL: pageURL)
    }

    func browserDidRequestCopyImageLink(forImageURL imageURL: String) {
        delegate?.engineTabDidRequestCopyImageLink(imageURL: imageURL)
    }

    func browserDidRequestDownloadImage(forImageURL imageURL: String) {
        delegate?.engineTabDidRequestDownloadImage(imageURL: imageURL)
    }

    func browserDidRequestNewTab(forURL url: String, disposition: BRWWindowOpenDisposition) {
        let engineDisposition: EngineWindowOpenDisposition
        switch disposition {
        case .foregroundTab: engineDisposition = .foregroundTab
        case .backgroundTab: engineDisposition = .backgroundTab
        case .newWindow: engineDisposition = .newWindow
        case .newPopup: engineDisposition = .newPopup
        @unknown default: engineDisposition = .foregroundTab
        }
        delegate?.engineTabDidRequestNewTab(url: url, disposition: engineDisposition)
    }

    func browserDidRequestClose() {
        delegate?.engineTabDidRequestClose()
    }

    func browserDidBlockRequest(toTracker trackerDomain: String, onPageHost pageHost: String) {
        delegate?.engineTabDidBlockRequest(trackerDomain: trackerDomain, pageHost: pageHost)
    }
}

// `ActiveEngine` -- what the rest of Sources/App actually calls
// (`ActiveEngine.initialize(...)`, `ActiveEngine.createTab(...)`, etc.) --
// lives in WebKitEngineAdapter.swift as a runtime-selected
// `BrowserEngine.Type`, so `--engine cef|webkit` can pick between this
// file's CEFEngine and that file's WebKitEngine at launch. See that
// declaration's own doc comment.
