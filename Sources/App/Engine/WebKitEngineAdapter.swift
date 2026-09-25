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
    static func shouldWarn(host: String, profileName: String) -> Bool {
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

    static func interstitialDataURL(host: String, originalURL: String) -> String? {
        threatInterstitialBuilder?(host, originalURL)
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
final class WebKitTab: NSObject, EngineTab {
    weak var delegate: EngineTabDelegate?

    let webView: WKWebView
    let profileName: String
    private var observations: [NSKeyValueObservation] = []
    private var isFindingActive = false
    /// Bumped per find/stop so a slower, superseded result never overwrites
    /// a newer one in the find bar.
    private var findGeneration = 0
    private var findQuery: String?
    private var findMatchCase = false
    private var findOrdinal = 0

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

    /// WKWebView.find selects and scrolls to the match but reports only
    /// found / not found. The "3 of 12" CEF reports is rebuilt from a text
    /// walk (WebKitFindScript) run after each find: the count directly, and
    /// the ordinal from where WebKit's own selection landed. When the
    /// selection is somewhere the walk can't see (a form field, an iframe),
    /// the ordinal is stepped from the previous result instead. Delivered
    /// once, as a final update -- the find bar only ever shows the last one.
    func find(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        guard !searchText.isEmpty else {
            stopFinding(clearSelection: true)
            return
        }
        isFindingActive = true
        findGeneration += 1
        let generation = findGeneration
        let isNewSearch = !findNext || searchText != findQuery || matchCase != findMatchCase
        findQuery = searchText
        findMatchCase = matchCase

        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = matchCase
        config.wraps = true
        webView.find(searchText, configuration: config) { [weak self] result in
            guard let self, generation == self.findGeneration else { return }
            guard result.matchFound else {
                self.findOrdinal = 0
                self.delegate?.engineTabDidUpdateFindResult(matchCount: 0, activeMatchOrdinal: 0, isFinalUpdate: true)
                return
            }
            self.countFindMatches(searchText, matchCase: matchCase) { counted, selectedOrdinal in
                guard generation == self.findGeneration else { return }
                // WebKit found at least one, whatever the walk managed to see.
                let count = max(counted, 1)
                let ordinal: Int
                if selectedOrdinal > 0 {
                    ordinal = selectedOrdinal
                } else if isNewSearch || self.findOrdinal == 0 {
                    ordinal = 1
                } else if forward {
                    ordinal = self.findOrdinal % count + 1
                } else {
                    ordinal = self.findOrdinal <= 1 ? count : self.findOrdinal - 1
                }
                self.findOrdinal = min(ordinal, count)
                self.delegate?.engineTabDidUpdateFindResult(matchCount: count, activeMatchOrdinal: self.findOrdinal, isFinalUpdate: true)
            }
        }
    }

    private func countFindMatches(_ query: String, matchCase: Bool, completion: @escaping (_ count: Int, _ selectedOrdinal: Int) -> Void) {
        webView.callAsyncJavaScript(
            WebKitFindScript.countMatches,
            arguments: ["query": query, "matchCase": matchCase],
            in: nil,
            in: .defaultClient
        ) { result in
            switch result {
            case .success(let value):
                let numbers = (value as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                completion(numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 0)
            case .failure(let error):
                NSLog("Browser: WebKit find match count failed: %@", error.localizedDescription)
                completion(0, 0)
            }
        }
    }

    /// No explicit "cancel current search" API on WKWebView either --
    /// approximated by clearing the page's own text selection via injected
    /// JS, which is what findString's own selection-highlighting is built
    /// on top of (see WKWebView.h's -findString:withConfiguration:completionHandler:
    /// doc comment: "A match found by the search is selected").
    func stopFinding(clearSelection: Bool) {
        isFindingActive = false
        findGeneration += 1
        findQuery = nil
        findOrdinal = 0
        guard clearSelection else { return }
        webView.evaluateJavaScript("window.getSelection() && window.getSelection().removeAllRanges();", completionHandler: nil)
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
