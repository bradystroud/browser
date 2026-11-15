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
            devToolsDocking: true,
            devToolsHasOwnChrome: false,
            responsiveDesignMode: true,
            perTabCPUUsage: true,
            perTabAudioMute: true,
            customContextMenuItems: true,
            // Chromium's own extension system, loaded from the switch: see
            // CEFExtensionRuntime.
            webExtensions: CEFExtensionRuntime.shared.isAvailable,
            extensionActionsAreStatic: true,
            extensionChangesNeedRelaunch: true,
            pageAutoResize: true,
            agentControl: true)
    }

    /// Whenever this macOS supports extensions, also when they are off in
    /// this session: the consent note follows the next launch's setting.
    static var extensionRuntime: FollowerExtensionRuntime? {
        CEFExtensionRuntime.shared.isSupported ? CEFExtensionRuntime.shared : nil
    }

    static func initialize(profilesRootPath: String) -> Bool {
        CEFExtensionRuntime.shared.prepareBeforeEngineStart(profilesRootPath: profilesRootPath)
        // An extension switch on the app's own command line is kept only by a
        // build outside /Applications launched on its own scratch profiles
        // root (not the real one, nor inside or around it); a real install
        // never loads an extension it did not prepare.
        let isTestLaunch = Bundle.main.bundlePath != DevBuildIndicator.installedBundlePath
            && CommandLineArgs.allowsAgentExtensionsRoot
        BRWExtensionRuntime.setKeepsExternalExtensionSwitches(isTestLaunch)
        return BRWEngine.initialize(withProfilesRootPath: profilesRootPath)
    }

    /// Chromium loads switch extensions into the whole profile context, so a
    /// tab that must not run them (`runsExtensions` false) cannot be one of
    /// that context's tabs while the profile runs any: it stays empty, and
    /// `browser page open` refuses before it gets here.
    static func createTab(profileName: String, profileId: String, hostView: NSView, initialURL: String, runsExtensions: Bool) -> EngineTab {
        CEFTab(profileName: profileName, profileId: profileId, hostView: hostView, initialURL: initialURL, runsExtensions: runsExtensions)
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

    /// Whether `tab` is one of this engine's.
    static func owns(_ tab: EngineTab) -> Bool { tab is CEFTab }

    static func setVisualLookUpAvailable(_ available: Bool) {
        BRWBrowser.setVisualLookUpAvailable(available)
    }

    /// CEF never unloads or suspends a hidden tab on its own, so there is
    /// nothing to configure (capabilities.backgroundTabPolicy is false).
    static func setBackgroundTabPolicy(_ policy: BackgroundTabPolicy) {}

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
///
/// A profile tab's browser is created only once its profile's context is
/// ready with the profile's own extensions (CEFExtensionRuntime); until then
/// `browser` is nil, and calls either wait for it (`withBrowser`) or answer
/// as a page that has not loaded would.
private final class CEFTab: NSObject, EngineTab, BRWBrowserDelegate {
    weak var delegate: EngineTabDelegate?
    private var browser: BRWBrowser?
    /// Calls made before the browser existed, run in order when it does;
    /// each one's cancel runs instead if the tab closes first.
    private var pendingCalls: [(run: (BRWBrowser) -> Void, cancel: (() -> Void)?)] = []
    private var pendingURL: String?
    private var isClosed = false
    /// Nil for a private tab.
    private let profileId: String?

    private var siteStyleSheets: [String: String] = [:]
    /// The URL of the document the main frame actually holds, as OnLoadStart
    /// reported it. Not OnAddressChange's URL: that already shows a pending
    /// navigation's destination while the old document is still live.
    private var currentMainFrameURL: String?

    init(profileName: String, profileId: String, hostView: NSView, initialURL: String, runsExtensions: Bool) {
        self.profileId = profileId
        super.init()
        if !runsExtensions, CEFExtensionRuntime.shared.extensionsReachEveryTab(profileId: profileId) {
            NSLog("Browser: not opening a tab that may not run extensions in profile %@: its Chromium context runs them", profileId)
            isClosed = true
            // Said where an agent reads why its page never loaded.
            mainDocumentLoad = EngineMainDocumentLoad(
                url: initialURL, httpStatus: nil,
                error: "This profile runs extensions in Chromium tabs, and this page may not run them")
            return
        }
        CEFExtensionRuntime.shared.whenProfileReady(profileId) { [weak self] in
            guard let self, !self.isClosed else { return }
            let browser = BRWBrowser(profileName: profileName, profileId: profileId, hostView: hostView,
                                     initialURL: self.pendingURL ?? initialURL)
            browser.delegate = self
            self.browser = browser
            let calls = self.pendingCalls
            self.pendingCalls = []
            calls.forEach { $0.run(browser) }
        }
    }

    /// Runs `call` on the browser now, or once it exists; `onCancel` when
    /// the tab closes without one.
    private func withBrowser(_ call: @escaping (BRWBrowser) -> Void, onCancel: (() -> Void)? = nil) {
        if let browser { return call(browser) }
        guard !isClosed else { onCancel?(); return }
        pendingCalls.append((call, onCancel))
    }

    private lazy var protocolAutomation: DevToolsProtocolAutomation = {
        DevToolsProtocolAutomation(
            execute: { [weak self] method, params, completion in
                guard let self, !self.isClosed else { return completion(false, #"{"message":"the page closed"}"#) }
                self.withBrowser({ $0.executeAutomationMethod(method, paramsJSON: params, completion: completion) },
                                 onCancel: { completion(false, #"{"message":"the page closed"}"#) })
            },
            setEventHandler: { [weak self] handler in
                self?.withBrowser { $0.setAutomationEventHandler(handler) }
            },
            setAllowsPopups: { [weak self] allow in
                self?.withBrowser { $0.setAllowsPopupsWithoutGesture(allow) }
            })
    }()

    var automation: EngineTabAutomation? { protocolAutomation }

    /// Private Browsing (browser-12m.1) -- see BRWBrowser.h's
    /// -initPrivateWithHostView:initialURL: for what makes this different
    /// from the designated initializer above.
    init(privateHostView hostView: NSView, initialURL: String) {
        let browser = BRWBrowser(privateWithHostView: hostView, initialURL: initialURL)
        self.browser = browser
        profileId = nil
        super.init()
        browser.delegate = self
    }

    func loadURL(_ url: String) {
        if let browser { return browser.loadURL(url) }
        pendingURL = url
    }
    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }
    func stopLoading() { browser?.stopLoad() }
    func close() {
        isClosed = true
        let cancelled = pendingCalls
        pendingCalls = []
        cancelled.forEach { $0.cancel?() }
        browser?.close()
    }

    /// Where docked tools currently live, so the picker and inspect-at-point
    /// open into the same place; nil means CEF's own separate window.
    private weak var devToolsContainer: NSView?

    var isDevToolsOpen: Bool { browser?.isDevToolsOpen ?? false }

    func showDevTools(panel: DevToolsPanel, dockSide: DevToolsDockSide, in container: NSView?) {
        devToolsContainer = dockSide == .window ? nil : container
        browser?.showDevTools(in: devToolsContainer, panel: Self.bridgePanel(panel))
    }
    func closeDevTools() { browser?.closeDevTools() }
    func startElementPicker() { browser?.startElementPicker(in: devToolsContainer) }
    func inspectElement(at point: NSPoint) { browser?.inspectElement(at: point, in: devToolsContainer) }

    private static func bridgePanel(_ panel: DevToolsPanel) -> BRWDevToolsPanel {
        switch panel {
        case .default: return .default
        case .console: return .console
        case .elements: return .elements
        }
    }

    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        withBrowser { $0.setResponsiveDesignMode(width: Int32(width), height: Int32(height), deviceScaleFactor: deviceScaleFactor, mobile: mobile) }
    }
    func clearResponsiveDesignMode() { withBrowser { $0.clearResponsiveDesignMode() } }
    func cpuUsagePercent() -> Double { browser?.cpuUsagePercent() ?? 0 }
    var contentProcessIdentifier: pid_t? { nil }
    func setAudioMuted(_ muted: Bool) { withBrowser { $0.setAudioMuted(muted) } }
    func setZoomLevel(_ level: Double) { withBrowser { $0.setZoomLevel(level) } }
    func zoomLevel() -> Double { browser?.zoomLevel() ?? 0 }
    func print() { browser?.print() }

    /// Chromium already judged the certificate (hasCertificateError), so the
    /// trust built here is only for showing the chain in the system's
    /// certificate viewer; nothing evaluates it.
    func securityStatus() -> EngineSecurityStatus? {
        guard let status = browser?.securityStatus() else { return nil }
        let certificates = status.certificateChain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        if !certificates.isEmpty {
            SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, nil), &trust)
        }
        return EngineSecurityStatus(
            isSecureConnection: status.isSecureConnection,
            hasCertificateError: status.hasCertificateError,
            hasInsecureContent: status.hasInsecureContent,
            serverTrust: trust)
    }
    func printToPDF(path: String, completion: @escaping (Bool, String) -> Void) {
        guard let browser else { return completion(false, "The page has not loaded yet.") }
        browser.printToPDF(withPath: path, completion: completion)
    }
    func downloadImage(url: String, completion: @escaping (Data?, Int) -> Void) {
        guard let browser else { return completion(nil, 0) }
        browser.downloadImage(atURL: url) { pngData, httpStatusCode in
            completion(pngData, httpStatusCode)
        }
    }
    func startDownload(url: String) {
        withBrowser { $0.startDownload(forURL: url) }
    }
    func find(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        browser?.find(searchText, forward: forward, matchCase: matchCase, findNext: findNext)
    }
    func stopFinding(clearSelection: Bool) {
        browser?.stopFinding(clearSelection)
    }
    func executeJavaScript(_ code: String) {
        browser?.executeJavaScript(code)
    }

    /// CEF offers no document-start user script without renderer-side code,
    /// so the sheet goes in at OnLoadStart -- after commit, before the new
    /// document has painted. Only the matching site's sheet is ever sent to
    /// the page, never the whole map: this runs in the page's own world.
    func setSiteStyleSheets(_ sheetsBySite: [String: String]) {
        siteStyleSheets = sheetsBySite
        browser?.executeJavaScript(SiteStyleSheetScript.apply(css: siteStyleSheetCSS(for: currentMainFrameURL)))
    }

    private func siteStyleSheetCSS(for url: String?) -> String {
        guard !siteStyleSheets.isEmpty, let url, let host = URL(string: url)?.host else { return "" }
        return SiteStyleSheetScript.css(forHost: host, in: siteStyleSheets)
    }

    func getPageSource(completion: @escaping (String?) -> Void) {
        guard let browser else { return completion(nil) }
        browser.getPageSource(completion: completion)
    }
    func respondToPageMessage(requestId: Int64, success: Bool, response: String) {
        browser?.respondToPageMessage(withId: requestId, success: success, response: response)
    }

    func setAutoResize(enabled: Bool, minSize: NSSize, maxSize: NSSize) {
        withBrowser { $0.setAutoResize(enabled: enabled, minSize: minSize, maxSize: maxSize) }
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

    func browserShouldStartMainFrameNavigation(to url: String) -> Bool {
        delegate?.engineTabShouldStartMainFrameNavigation(url) ?? true
    }

    func browserDidUpdateLoadingProgress(_ progress: Double) {
        delegate?.engineTabDidUpdateLoadingProgress(progress)
    }

    func browserDidCommitNavigation(_ url: String) {
        delegate?.engineTabDidCommitNavigation(url)
    }

    private(set) var mainDocumentLoad: EngineMainDocumentLoad?

    func browserDidFinishMainFrameLoad(withURL url: String, httpStatusCode: Int) {
        // Chromium's own error page for a failed load ends with status 0 at
        // the same URL; the failure it shows is the one to keep.
        if httpStatusCode <= 0, let last = mainDocumentLoad, last.error != nil, last.url == url { return }
        mainDocumentLoad = EngineMainDocumentLoad(url: url, httpStatus: httpStatusCode > 0 ? httpStatusCode : nil)
    }

    func browserDidFailMainFrameLoad(withURL url: String, errorCode: Int, errorText: String) {
        mainDocumentLoad = EngineMainDocumentLoad(url: url, httpStatus: nil, error: "\(errorText) (\(errorCode))")
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

    func browserDidReceivePageMessage(_ request: String, requestId: Int64, isMainFrame: Bool, frameURL: String) {
        delegate?.engineTabDidReceivePageMessage(
            request, requestId: requestId, source: PageMessageSource(isMainFrame: isMainFrame, frameURL: frameURL))
    }

    func browserDidStartMainFrameLoad(withURL url: String) {
        currentMainFrameURL = url
        let css = siteStyleSheetCSS(for: url)
        if !css.isEmpty {
            browser?.executeJavaScript(SiteStyleSheetScript.apply(css: css))
        }
        delegate?.engineTabDidStartMainFrameLoad()
    }

    func browserDidRequestVisualLookUp(forImageURL imageURL: String, pageURL: String) {
        delegate?.engineTabDidRequestVisualLookUp(imageURL: imageURL, pageURL: pageURL)
    }

    func browserDidRequestViewSource(forPageURL pageURL: String) {
        delegate?.engineTabDidRequestViewSource(pageURL: pageURL)
    }

    func browserDidRequestSiteInformation() {
        delegate?.engineTabDidRequestSiteInformation()
    }

    func browserDidRequestPeekLink(forURL linkURL: String) {
        delegate?.engineTabDidRequestPeekLink(url: linkURL)
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
        // The bridge lets an extension's page open only its own pages; the
        // extension runtime decides where they show (an action popup, or a
        // tab in this engine, where that extension runs). Outside CEF's
        // callback: showing it may close the popup this page is in.
        if let profileId, let target = URL(string: url), target.scheme?.lowercased() == "chrome-extension" {
            let asWindow = disposition == .newPopup || disposition == .newWindow
            DispatchQueue.main.async {
                CEFExtensionRuntime.shared.extensionPageRequestedOpen(target, profileId: profileId, asWindow: asWindow)
            }
            return
        }
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

    func browserDevToolsDidOpen() {
        delegate?.engineTabDevToolsDidOpen()
    }

    func browserDevToolsDidClose() {
        delegate?.engineTabDevToolsDidClose()
    }

    @objc(browserDidRequestInspectElementAtPoint:)
    func browserDidRequestInspectElement(at point: NSPoint) {
        delegate?.engineTabDidRequestInspectElement(at: point)
    }

    func browserDidAutoResize(to size: NSSize) {
        delegate?.engineTabDidAutoResize(to: size)
    }

    func browserDidBlockRequest(toTracker trackerDomain: String, onPageHost pageHost: String) {
        delegate?.engineTabDidBlockRequest(trackerDomain: trackerDomain, pageHost: pageHost)
    }
}
