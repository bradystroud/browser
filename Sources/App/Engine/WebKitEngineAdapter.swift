import AppKit
import WebKit

// ContentRuleListBuilder and ProfileDataStoreKey come from
// Packages/WebEngineCore/Sources/WebEngineCore -- compiled directly into
// this same target by Sources/App/CMakeLists.txt (see its
// BROWSER_WEBENGINE_CORE_SRCS), the same "one copy of the logic, two ways
// to build it" pattern as BlockList/BlockingSettings (BlockListCore) and
// ProfilesRootResolver (BrowserCore) elsewhere in this file's sibling
// sources -- so no `import WebEngineCore` here, matching how those other
// packages' types are used directly elsewhere in Sources/App.

/// A second, WKWebView-backed `BrowserEngine` conformer alongside
/// `CEFEngineAdapter.swift`'s `CEFEngine` -- exploratory/spike-quality
/// (browser-n50), not a shipped daily-driver engine. Every EngineTab/
/// BrowserEngine member was checked against the WebKit.framework headers:
/// what has a real WKWebView equivalent is wired up here, and what doesn't
/// is a logged, safe no-op whose comment says why.
///
/// Selected via `--engine webkit` (default `cef`) -- see
/// `CommandLineArgs.engineChoice()` and `main.swift`'s `ActiveEngine`.
///
/// Everything WebKit-specific is confined to this file and
/// `Packages/WebEngineCore` (the pure, testable logic pulled out of it) --
/// exactly the same "one file owns the bridge-specific symbols" shape
/// `CEFEngine`/`CEFTab` established, just with WKWebView/WebKit.framework
/// types standing in for BRW*/CEF ones.
enum WebKitEngine: BrowserEngine {
    static func bootstrapApplication() {
        // CEF requires BRWApplication -- a custom NSApplication subclass --
        // to become NSApp before anything else touches it, because CEF's
        // own external message pump needs to intercept AppKit's event
        // dispatch (see BRWApplication.h / BRWMessagePump.mm) and because
        // -[BRWApplication terminate:] runs CEF's own multi-process,
        // wait-for-every-browser-to-close shutdown handshake before AppKit's
        // normal -terminate: proceeds. WKWebView needs neither: it's an
        // ordinary in-process NSView with synchronous, ARC-managed teardown,
        // so a stock NSApplication is sufficient here.
        //
        // Real gap this leaves: CEF's shutdown
        // handshake is exactly what makes AppDelegate's registered close
        // handler (see setWindowCloseHandler below) actually get invoked at
        // quit time, via -[BRWApplication terminate:] calling it before
        // deferring to super. Nothing plays that role here, so under this
        // engine WindowManager.closeAllWindowsForShutdown() -- and whatever
        // session-save-on-quit behavior it implements -- never runs unless
        // AppDelegate itself is changed to call it directly rather than
        // relying on the engine to. Flagged rather than worked around: fixing
        // it means moving that responsibility up a layer (AppDelegate always
        // owns quit sequencing; an engine only gets to *delay* it if it needs
        // to, which WebKit doesn't), which is a decision for
        // browser-n50.5's decision checkpoint, not something this adapter
        // should quietly paper over.
    }

    private static var contentRuleListStore: WKContentRuleListStore?

    /// Per-profile compiled content-blocking rule list, keyed by profile
    /// name (or "private" -- see BRWBrowser.mm's private-window profile-name
    /// convention this mirrors). Populated asynchronously by
    /// updateContentBlocking(domains:profileSettings:) below; a tab created
    /// before its profile's first compile finishes just has no rule list
    /// attached yet (fails open, same direction BRWContentBlockerShouldBlock
    /// itself fails in) until the next update.
    fileprivate static var compiledContentRuleLists: [String: WKContentRuleList] = [:]

    /// Every live tab, by profile name, so a content-blocking update can
    /// push a freshly-compiled rule list into already-open tabs -- unlike
    /// CEF's single atomically-published snapshot BRWClientHandler reads
    /// per-request, a WKContentRuleList must be explicitly (re-)attached to
    /// each WKWebView's own WKUserContentController. Weak so a closed tab
    /// falls out of this registry on its own.
    private static var liveTabsByProfile: [String: NSHashTable<WebKitTab>] = [:]

    private static var threatDomains: [String] = []
    private static var threatProfileSettings: [String: EngineProfileThreatSettings] = [:]
    private static var threatInterstitialBuilder: ((String, String) -> String)?

    private static var windowCloseHandler: (() -> Void)?
    private(set) static var isTerminating = false
    private(set) static var visualLookUpAvailable = false

    static func initialize(profilesRootPath: String) -> Bool {
        // WKWebsiteDataStore(forIdentifier:) manages its own on-disk location
        // internally with no public relocation API (confirmed against
        // WKWebsiteDataStore.h -- no path/URL property or parameter
        // anywhere), unlike CEF's explicit root_cache_path. profilesRootPath
        // is still put to use for the one piece of WebKit storage that *does*
        // take an explicit URL: WKContentRuleListStore, which caches compiled
        // rule lists on disk keyed by identifier.
        let storeURL = URL(fileURLWithPath: profilesRootPath, isDirectory: true)
            .appendingPathComponent("WebKitContentRuleLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        contentRuleListStore = WKContentRuleListStore(url: storeURL)
        return true
    }

    // The tab's WKWebsiteDataStore is keyed by `profileId`, so renaming a
    // profile never orphans its cookies/storage. Content-blocking and
    // threat-warning state stay keyed by `profileName`, because that is how
    // ContentBlockerCoordinator/ThreatListCoordinator hand them over.
    static func createTab(profileName: String, profileId: String, hostView: NSView, initialURL: String) -> EngineTab {
        let tab = WebKitTab(profileName: profileName, profileId: profileId, hostView: hostView, initialURL: initialURL)
        register(tab, profileName: profileName)
        return tab
    }

    static func createPrivateTab(hostView: NSView, initialURL: String) -> EngineTab {
        let tab = WebKitTab(privateHostView: hostView, initialURL: initialURL)
        register(tab, profileName: "private")
        return tab
    }

    private static func register(_ tab: WebKitTab, profileName: String) {
        let table = liveTabsByProfile[profileName] ?? NSHashTable<WebKitTab>.weakObjects()
        table.add(tab)
        liveTabsByProfile[profileName] = table
        if let ruleList = compiledContentRuleLists[profileName] {
            tab.applyContentRuleList(ruleList)
        }
    }

    static func setWindowCloseHandler(_ handler: @escaping () -> Void) {
        windowCloseHandler = handler
    }

    static func setVisualLookUpAvailable(_ available: Bool) {
        // No macOS WKWebView hook to wire this to at all: WKUIDelegate's
        // -webView:contextMenuConfigurationForElement:completionHandler: --
        // the one API that could add a custom right-click item -- is
        // iOS-only (API_AVAILABLE(ios(13.0)), confirmed absent for macOS in
        // WKUIDelegate.h). There is no public way to customize WKWebView's
        // native macOS context menu at all, so "Look Up Image" (or any other
        // custom item) simply cannot exist on this engine. Stored only so
        // the flag has somewhere to go; nothing reads it.
        visualLookUpAvailable = available
    }

    /// Honoured, unlike setVisualLookUpAvailable above -- this one has a real
    /// destination on this engine: WKDownloadDelegate's
    /// -download:decideDestinationUsing:... below picks the path itself, so
    /// it just reads this instead of hardcoding ~/Downloads. That matters
    /// for the same reason as on CEF: an isolated `--profiles-root` test
    /// launch must not write into the real Downloads folder.
    static func setDownloadDirectory(_ path: String) {
        downloadDirectory = path
    }

    private(set) static var downloadDirectory = ""

    static func updateContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings]) {
        guard let store = contentRuleListStore else { return }
        for (profileName, settings) in profileSettings {
            guard settings.enabled else {
                compiledContentRuleLists.removeValue(forKey: profileName)
                liveTabsByProfile[profileName]?.allObjects.forEach { $0.removeContentRuleList() }
                continue
            }
            let json = ContentRuleListBuilder.json(blockedDomains: domains, allowlistedHosts: settings.allowlistedHosts)
            let identifier = "content-blocker.\(profileName)"
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { ruleList, error in
                if let error {
                    NSLog("Browser: WebKit content rule list compile failed for profile %@: %@", profileName, error.localizedDescription)
                    return
                }
                guard let ruleList else { return }
                compiledContentRuleLists[profileName] = ruleList
                liveTabsByProfile[profileName]?.allObjects.forEach { $0.applyContentRuleList(ruleList) }
            }
        }
    }

    static func setThreatInterstitialBuilder(_ builder: @escaping (String, String) -> String) {
        threatInterstitialBuilder = builder
    }

    static func updateThreatBlocking(domains: [String], profileSettings: [String: EngineProfileThreatSettings]) {
        threatDomains = domains
        threatProfileSettings = profileSettings
    }

    /// WKContentRuleList can only block/redirect a request, not render
    /// arbitrary interstitial HTML (see WKContentRuleList.h), so the threat
    /// warning -- unlike ad/tracker blocking above -- can't be implemented
    /// as a compiled rule list at all. Each WebKitTab instead checks
    /// main-frame navigations against this snapshot itself, in
    /// decidePolicyForNavigationAction, and loads the interstitial via
    /// threatInterstitialBuilder if it matches -- see WebKitTab's own
    /// implementation.
    fileprivate static func shouldWarn(host: String, profileName: String) -> Bool {
        guard threatProfileSettings[profileName]?.enabled == true else { return false }
        let hostLabels = host.lowercased().split(separator: ".")
        for domain in threatDomains {
            let domainLabels = domain.lowercased().split(separator: ".")
            guard !domainLabels.isEmpty, domainLabels.count <= hostLabels.count else { continue }
            if hostLabels.suffix(domainLabels.count).elementsEqual(domainLabels) {
                return true
            }
        }
        return false
    }

    fileprivate static func interstitialDataURL(host: String, originalURL: String) -> String? {
        threatInterstitialBuilder?(host, originalURL)
    }
}

/// Process-wide, cross-tab registry for the generic page<->native message
/// channel -- the WebKit equivalent of CEF's window.cefQuery, built on
/// WKScriptMessageHandlerWithReply (confirmed present, a genuine two-way
/// channel unlike plain WKScriptMessageHandler's fire-and-forget). Global,
/// matching EngineTab.respondToPageMessage's own documented contract that
/// `requestId` is global across every tab, not scoped to whichever tab
/// receives the eventual response call.
private enum PageMessageBridge {
    private static var nextRequestId: Int64 = 1
    private static var pendingReplies: [Int64: (Bool, String) -> Void] = [:]

    static func nextId(replyHandler: @escaping (Bool, String) -> Void) -> Int64 {
        let id = nextRequestId
        nextRequestId += 1
        pendingReplies[id] = replyHandler
        return id
    }

    static func respond(requestId: Int64, success: Bool, response: String) {
        guard let handler = pendingReplies.removeValue(forKey: requestId) else { return }
        handler(success, response)
    }
}

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

/// Wraps a single WKWebView, translating its KVO/WKNavigationDelegate/
/// WKUIDelegate/WKDownloadDelegate callbacks into EngineTabDelegate calls --
/// the WebKit-side counterpart of CEFEngineAdapter.swift's CEFTab. `final`,
/// not `private`, only so it can be held in the NSHashTable registry above
/// (private types can't satisfy NSHashTable's ObjC-visible generic
/// constraint); still not exported from this file's actual API surface --
/// nothing outside WebKitEngine ever sees a WebKitTab, only the EngineTab
/// protocol WebKitEngine.createTab(s) return.
final class WebKitTab: NSObject, EngineTab, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandlerWithReply {
    weak var delegate: EngineTabDelegate?

    private let webView: WKWebView
    private let profileName: String
    private var observations: [NSKeyValueObservation] = []
    private var isFindingActive = false

    private static let pageMessageHandlerName = "brwPageMessage"

    init(profileName: String, profileId: String, hostView: NSView, initialURL: String) {
        self.profileName = profileName
        let config = WKWebViewConfiguration()
        // WKWebsiteDataStore(forIdentifier:) is macOS 14.0+ (see
        // WKWebsiteDataStore.h) -- this app's deployment target is 12.0, so
        // on macOS 12/13 there is no public way to get a persistent,
        // per-profile-identity data store at all, and every profile
        // silently shares WebKit's single default store instead (a real
        // profile-isolation regression on those OS versions specifically,
        // not just a missing nice-to-have).
        if #available(macOS 14.0, *) {
            let uuid = ProfileDataStoreKey.identifier(forProfileId: profileId)
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: uuid)
        }
        webView = WKWebView(frame: hostView.bounds, configuration: config)
        super.init()
        finishInit(hostView: hostView, initialURL: initialURL, config: config)
    }

    /// Private Browsing (browser-12m.1) -- WKWebsiteDataStore.nonPersistent()
    /// is WebKit's own documented incognito mode (see WKWebsiteDataStore.h:
    /// "no data will be written to the file system"), a new instance per
    /// call exactly like BRWBrowser's own ephemeral CefRequestContext, so two
    /// private tabs never share cookies/storage with each other either.
    /// Unlike the named-profile initializer above, this needs no macOS 14
    /// guard -- nonPersistent() has been available since macOS 10.11.
    init(privateHostView hostView: NSView, initialURL: String) {
        profileName = "private"
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: hostView.bounds, configuration: config)
        super.init()
        finishInit(hostView: hostView, initialURL: initialURL, config: config)
    }

    private func finishInit(hostView: NSView, initialURL: String, config: WKWebViewConfiguration) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: WebKitTab.pageMessageHandlerName)
        hostView.addSubview(webView)

        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, change in
            guard let title = change.newValue.flatMap({ $0 }) else { return }
            self?.delegate?.engineTabDidChangeTitle(title)
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let url = change.newValue.flatMap({ $0 })?.absoluteString else { return }
            self?.delegate?.engineTabDidChangeURL(url)
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            self?.delegate?.engineTabDidChangeLoadingState(webView.isLoading, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            self?.delegate?.engineTabDidChangeLoadingState(webView.isLoading, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            self?.delegate?.engineTabDidChangeLoadingState(webView.isLoading, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        })
        // No favicon KVO/delegate hook exists on WKWebView at all (no
        // public "favicon changed" signal, unlike CEF's own
        // browserDidChangeFaviconURL) -- engineTabDidChangeFaviconURL simply
        // never fires on this engine. A real implementation would need to
        // scrape <link rel="icon"> via injected JS (WebEngineCore has no
        // WebKit dependency to do this from, and it's a UI-polish gap, not
        // a functional one, so left unimplemented for this spike).

        if let ruleList = WebKitEngine.compiledContentRuleLists[profileName] {
            applyContentRuleList(ruleList)
        }

        loadURL(initialURL)
    }

    fileprivate func applyContentRuleList(_ ruleList: WKContentRuleList) {
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.configuration.userContentController.add(ruleList)
    }

    fileprivate func removeContentRuleList() {
        webView.configuration.userContentController.removeAllContentRuleLists()
    }

    // MARK: - EngineTab

    func loadURL(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        webView.load(URLRequest(url: parsed))
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func close() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebKitTab.pageMessageHandlerName)
        webView.removeFromSuperview()
    }

    func showDevTools() {
        // No public API to *open* Web Inspector at all -- Apple's
        // programmatic inspector API (_showInspector etc.) is private SPI,
        // Safari-only. isInspectable (macOS 13.3+) is the entire public
        // surface: it makes the tab available to attach to *externally*,
        // via Safari's Develop menu or the separate Web Inspector app, not
        // something this app can pop open itself the way CEF's -showDevTools
        // does with its own native window.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
            NSLog("Browser: WebKit engine has no in-app DevTools window -- attach via Safari's Develop menu (isInspectable = true is now set for this tab).")
        } else {
            NSLog("Browser: unsupported on WebKit engine: DevTools (isInspectable needs macOS 13.3+)")
        }
    }
    func closeDevTools() {
        // Can't force-close a separate app's (Safari's) inspector window
        // from here -- no-op, matching -showDevTools's own limitation above.
    }

    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        unsupported("Responsive Design Mode (no public device-emulation/DevTools-protocol API on WKWebView)")
    }
    func clearResponsiveDesignMode() {
        unsupported("Responsive Design Mode (no public device-emulation/DevTools-protocol API on WKWebView)")
    }

    func cpuUsagePercent() -> Double {
        unsupported("per-tab CPU usage (no CefTaskManager equivalent; WKWebView's renderer process stats aren't exposed publicly)")
        return 0
    }

    func setAudioMuted(_ muted: Bool) {
        unsupported("per-tab audio mute (confirmed: no public WKWebView API mutes page audio output -- WKWebExtensionTab's setMuted:forWebExtensionContext: is extension-API-only, not a general WKWebView property)")
    }

    /// Full parity on the mechanism, no workaround needed (browser-5kq.15):
    /// WKWebView.pageZoom is a real, public linear scale factor, so the only
    /// work here is converting out of (and back into) Chromium's logarithmic
    /// level units, which are what EngineTab speaks because CEF's own API does.
    ///
    /// One deliberate behavioural difference from the CEF adapter, noted rather
    /// than papered over: pageZoom is a property of this one web view, so on
    /// the WebKit engine zoom is genuinely per-tab, whereas CEF's is per host
    /// per profile (see EngineTab.setZoomLevel(_:)). Reading zoomLevel() back
    /// -- which the UI does on every access -- is correct under either.
    func setZoomLevel(_ level: Double) {
        webView.pageZoom = CGFloat(PageZoom.factor(forLevel: level))
    }

    func zoomLevel() -> Double {
        PageZoom.level(forFactor: Double(webView.pageZoom))
    }

    func print() {
        let operation = NSPrintOperation(view: webView)
        operation.run()
    }

    func printToPDF(path: String, completion: @escaping (Bool, String) -> Void) {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            switch result {
            case .success(let data):
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    completion(true, path)
                } catch {
                    NSLog("Browser: WebKit printToPDF write failed: %@", error.localizedDescription)
                    completion(false, path)
                }
            case .failure(let error):
                NSLog("Browser: WebKit createPDF failed: %@", error.localizedDescription)
                completion(false, path)
            }
        }
    }

    /// Best-effort approximation, not full parity: WKWebView.findString's
    /// completion handler (WKFindResult) reports only whether a match was
    /// found -- no match *count*, no active-match *ordinal*, unlike CEF's
    /// find, which reports both repeatedly as it scans (see
    /// EngineTabDidUpdateFindResult's own doc comment). There is no public
    /// WKWebView API that exposes either number, so a find bar built against
    /// this engine can show "found/not found" but not "3 of 12" the way it
    /// does on CEF today -- a real, confirmed UI regression for
    /// browser-5kq.5 parity, not just a rough edge.
    func find(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        guard !searchText.isEmpty else {
            stopFinding(clearSelection: true)
            return
        }
        isFindingActive = true
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = matchCase
        config.wraps = true
        webView.find(searchText, configuration: config) { [weak self] result in
            self?.delegate?.engineTabDidUpdateFindResult(
                matchCount: result.matchFound ? 1 : 0,
                activeMatchOrdinal: result.matchFound ? 1 : 0,
                isFinalUpdate: true)
        }
    }

    /// No explicit "cancel current search" API on WKWebView either --
    /// approximated by clearing the page's own text selection via injected
    /// JS, which is what findString's own selection-highlighting is built
    /// on top of (see WKWebView.h's -findString:withConfiguration:completionHandler:
    /// doc comment: "A match found by the search is selected").
    func stopFinding(clearSelection: Bool) {
        isFindingActive = false
        guard clearSelection else { return }
        webView.evaluateJavaScript("window.getSelection() && window.getSelection().removeAllRanges();", completionHandler: nil)
    }

    func executeJavaScript(_ code: String) {
        webView.evaluateJavaScript(code) { _, error in
            if let error {
                NSLog("Browser: WebKit executeJavaScript error: %@", error.localizedDescription)
            }
        }
    }

    /// Genuinely different mechanism from CEF's, with genuinely different
    /// coverage: WebKit has no `CefBrowserHost::DownloadImage` equivalent
    /// (nothing public hands back the bytes of an already-decoded image the
    /// page loaded), so this fetches inside the page instead. That still
    /// carries the page's cookies -- `credentials: "include"` on a fetch
    /// issued by the document itself -- but it is subject to CORS, unlike
    /// the CEF path: a cross-origin image whose host sends no
    /// `Access-Control-Allow-Origin` fails here and succeeds there.
    ///
    /// `httpStatusCode` is the real response status when the fetch got far
    /// enough to have one, and 0 otherwise.
    func downloadImage(url: String, completion: @escaping (Data?, Int) -> Void) {
        let encoded = String(data: (try? JSONEncoder().encode(url)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        let script = """
        (async () => {
          const response = await fetch(\(encoded), { credentials: "include" });
          const buffer = await response.arrayBuffer();
          let binary = "";
          const bytes = new Uint8Array(buffer);
          for (let i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
          return { status: response.status, base64: btoa(binary) };
        })()
        """
        webView.callAsyncJavaScript(script, in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                guard let dictionary = value as? [String: Any],
                      let base64 = dictionary["base64"] as? String,
                      let data = Data(base64Encoded: base64)
                else {
                    completion(nil, 0)
                    return
                }
                completion(data, dictionary["status"] as? Int ?? 0)
            case .failure(let error):
                NSLog("Browser: WebKit downloadImage failed: %@", error.localizedDescription)
                completion(nil, 0)
            }
        }
    }

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

    func getPageSource(completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let error {
                NSLog("Browser: WebKit getPageSource error: %@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }

    func respondToPageMessage(requestId: Int64, success: Bool, response: String) {
        PageMessageBridge.respond(requestId: requestId, success: success, response: response)
    }

    // MARK: - WKScriptMessageHandlerWithReply (window.cefQuery equivalent)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let request = message.body as? String else {
            replyHandler(nil, "invalid page message body")
            return
        }
        let requestId = PageMessageBridge.nextId { success, response in
            replyHandler(response, success ? nil : response)
        }
        delegate?.engineTabDidReceivePageMessage(request, requestId: requestId)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // target="_blank"/window.open() -- see
        // webView(_:createWebViewWith:for:windowFeatures:) below for the
        // matching new-tab signal. Threat-warning check (browser-12m.6) only
        // applies to top-level main-frame navigations, matching
        // BRWClientHandler::OnBeforeResourceLoad's own scope for this
        // feature.
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, let host = url.host,
           WebKitEngine.shouldWarn(host: host, profileName: profileName),
           let dataURLString = WebKitEngine.interstitialDataURL(host: host, originalURL: url.absoluteString),
           let dataURL = URL(string: dataURLString) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: dataURL))
            return
        }
        // Cmd/Cmd+Shift/Shift/middle-click on an ordinary <a href> -- the
        // WebKit counterpart of BRWClientHandler::OnOpenURLFromTab. WebKit
        // (unlike Blink) doesn't resolve these into a disposition itself, but
        // WKNavigationAction does carry the originating event's own modifiers
        // and button, so this stays race-free (no live keyboard-state query)
        // and still respects a page's own preventDefault(), which suppresses
        // the navigation before this is ever consulted.
        if let disposition = Self.clickDisposition(for: navigationAction),
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            delegate?.engineTabDidRequestNewTab(url: url.absoluteString, disposition: disposition)
            return
        }
        decisionHandler(.allow)
    }

    /// The standard macOS link-click modifier overrides, or nil for an
    /// ordinary click that should just navigate in place.
    private static func clickDisposition(for navigationAction: WKNavigationAction) -> EngineWindowOpenDisposition? {
        guard navigationAction.navigationType == .linkActivated else { return nil }
        // AppKit button numbers: 0 left, 1 right, 2 middle; -1 when the
        // navigation wasn't caused by a mouse event at all.
        if navigationAction.buttonNumber == 2 { return .backgroundTab }
        let modifiers = navigationAction.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) { return modifiers.contains(.shift) ? .foregroundTab : .backgroundTab }
        if modifiers.contains(.shift) { return .newWindow }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        delegate?.engineTabDidCommitNavigation(url)
        // Approximation, not CEF's exact guarantee: BRWBrowser's
        // -browserDidStartMainFrameLoad fires after commit but before the
        // new document's own scripts run (see BrowserEngine.swift's own doc
        // comment on the exact CEF contract). WKNavigationDelegate has no
        // equivalent hook -- didCommitNavigation fires once the response
        // begins arriving, close enough for this signal's actual use
        // (triggering a same-timing executeJavaScript(_:) injection) but not
        // a verified guarantee. The idiomatic WebKit way to guarantee
        // before-page-scripts injection is a persistent WKUserScript with
        // injectionTime .atDocumentStart added once to the
        // WKUserContentController -- a real production port of the
        // password-manager/autofill/notification-override scripts onto this
        // engine should very likely use that instead of reacting to this
        // signal with an imperative executeJavaScript(_:) call every time.
        delegate?.engineTabDidStartMainFrameLoad()
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Only invoked when navigationAction.targetFrame is nil -- i.e.
        // exactly the "wants a new browsing context" signal
        // (target="_blank"/window.open()) BRWClientHandler's own
        // OnOpenURLFromTab reports via -browserDidRequestNewTabForURL:disposition:.
        // Returning nil (rather than a real WKWebView) means WebKit does not
        // create its own child web view for it -- our own UI creates a real
        // tab instead, the same reason CEFTab's translation exists.
        delegate?.engineTabDidRequestNewTab(
            url: navigationAction.request.url?.absoluteString ?? "",
            disposition: Self.clickDisposition(for: navigationAction) ?? .foregroundTab)
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        var kinds: EnginePermissionKind = []
        switch type {
        case .camera: kinds = .camera
        case .microphone: kinds = .microphone
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: break
        }
        let promptId = UInt64.random(in: .min ... .max)
        delegate?.engineTabDidRequestPermission(kinds, promptId: promptId, requestingOrigin: origin.protocol + "://" + origin.host, decision: { allow in
            decisionHandler(allow ? .grant : .deny)
        })
        // No engineTabDidDismissPermissionRequest equivalent wired up:
        // WKUIDelegate gives no separate "the request went away" callback
        // the way CEF's own permission handler does -- this decisionHandler
        // either gets called or (if the page/frame goes away first) is
        // presumably released by WebKit uninvoked. Not verified without a
        // live test.
    }

    // Geolocation permission (-webView:requestGeolocationPermissionForOrigin:
    // initiatedByFrame:decisionHandler:) is API_AVAILABLE(macos(27.0)) only
    // (confirmed against WKUIDelegate.h on this machine's SDK) -- this
    // app's deployment target is 12.0, so there is no public WKUIDelegate
    // hook for geolocation permission on any Mac running an OS older than
    // the one this was written on. Notifications have no WKUIDelegate hook
    // at all in any OS version; this project's own CEF-side notification
    // support (Notifications/NotificationOverrideScript.swift) is already a
    // JS-level window.Notification polyfill talking to native code over the
    // generic page-message channel rather than a native permission API, so
    // the same architecture (ported onto this file's WKScriptMessageHandlerWithReply
    // channel above) would carry over to this engine -- unlike geolocation,
    // notifications are not blocked by anything WebKit-specific, just not
    // yet ported.

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

    // No engineTabDidChangeFaviconURL or engineTabDidRequestVisualLookUp --
    // see this file's other doc comments for why each is missing.

    /// Features already logged this session, so a repeatedly-called gap (a
    /// polled CPU reading, a mute toggle) logs once rather than every time.
    private static var loggedUnsupportedFeatures: Set<String> = []

    private func unsupported(_ what: String) {
        guard Self.loggedUnsupportedFeatures.insert(what).inserted else { return }
        NSLog("Browser: unsupported on WebKit engine: %@", what)
    }
}

/// The engine the app builds against -- see CommandLineArgs.engineChoice()
/// for the `--engine cef|webkit` launch argument (default cef) that picks
/// which of CEFEngine/WebKitEngine this resolves to at launch. BrowserEngine
/// has no Self-returning or associated-type requirements, so a
/// `BrowserEngine.Type` existential dispatches its static requirements
/// correctly at runtime -- this is a genuine runtime switch, not a
/// build-time flag standing in for one.
let ActiveEngine: BrowserEngine.Type = CommandLineArgs.engineChoice() == .webkit ? WebKitEngine.self : CEFEngine.self
