import AppKit
import WebKit

// ContentRuleListBuilder and ProfileDataStoreKey come from
// Packages/WebEngineCore/Sources/WebEngineCore -- compiled directly into
// this same target by Sources/App/CMakeLists.txt (see its
// BROWSER_WEBENGINE_CORE_SRCS), the same "one copy of the logic, two ways
// to build it" pattern as BlockList/BlockingSettings (BlockListCore) and
// ProfilesRootResolver (BrowserCore) -- so no `import WebEngineCore` in any
// Engine/WebKit*.swift file, matching how those other packages' types are
// used directly elsewhere in Sources/App.

/// A second, WKWebView-backed `BrowserEngine` conformer alongside
/// `CEFEngineAdapter.swift`'s `CEFEngine` -- exploratory/spike-quality
/// (browser-n50), not a shipped daily-driver engine. Every EngineTab/
/// BrowserEngine member was checked against the WebKit.framework headers:
/// what has a real WKWebView equivalent is wired up here, and what doesn't
/// is a logged, safe no-op whose comment says why.
///
/// Selected via `--engine webkit` (default `cef`) -- see
/// `CommandLineArgs.engineChoice()` and `ActiveEngine` at the end of this file.
///
/// Everything WebKit-specific is confined to the Engine/WebKit*.swift files
/// -- this one, WebKitTab's per-area extensions (WebKitTab+*.swift) and the
/// helpers they use -- and `Packages/WebEngineCore` (the pure, testable
/// logic pulled out of them): the same "the adapter owns the engine-specific
/// symbols" shape `CEFEngine`/`CEFTab` established, with WKWebView/
/// WebKit.framework types standing in for BRW*/CEF ones.
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
        // so a stock NSApplication is sufficient here. The one thing that
        // handshake also does -- running the app's window close handler at
        // quit -- is done from willTerminateNotification instead; see
        // setWindowCloseHandler.
    }

    /// Whether the in-app Web Inspector (private _WKInspector SPI) exists on
    /// this system; without it, showDevTools(panel:dockSide:in:) points at Safari instead.
    static var inAppInspectorAvailable: Bool { WebKitInspector.isAvailable }

    /// Per-tab mute is done in page script (every media element muted), not
    /// by the engine. Device emulation relies on private WKWebView SPI and is
    /// offered only when that SPI exists. CPU use has no WKWebView API, and
    /// macOS WKWebView offers no way to add context-menu items.
    static var capabilities: EngineCapabilities {
        EngineCapabilities(
            inAppDevTools: inAppInspectorAvailable,
            devToolsDocking: WebKitInspector.canDockIntoContainer,
            devToolsHasOwnChrome: true,
            responsiveDesignMode: WebKitResponsiveDesign.isAvailable,
            perTabCPUUsage: false,
            perTabAudioMute: true,
            customContextMenuItems: false,
            backgroundTabPolicy: WebKitBackgroundTabPolicy.isAvailable,
            nativeSwipeNavigation: true,
            webExtensions: extensionsAvailable)
    }

    /// WKWebExtension is macOS 15.4+.
    static var extensionsAvailable: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    static var extensions: EngineExtensionManager? {
        if #available(macOS 15.4, *) { return WebKitExtensionManager.shared }
        return nil
    }

    static var contentRuleListStore: WKContentRuleListStore?

    /// Per-profile compiled content-blocking rule lists, keyed by profile
    /// name (or "private" -- see BRWBrowser.mm's private-window profile-name
    /// convention this mirrors). Populated asynchronously by
    /// WebKitContentBlocking.swift; a tab created
    /// before its profile's first compile finishes just has no rule list
    /// attached yet (fails open, same direction BRWContentBlockerShouldBlock
    /// itself fails in) until the next update.
    static var compiledContentRuleLists: [String: [WKContentRuleList]] = [:]

    /// Every live tab, by profile name, so a content-blocking update can
    /// push a freshly-compiled rule list into already-open tabs -- unlike
    /// CEF's single atomically-published snapshot BRWClientHandler reads
    /// per-request, a WKContentRuleList must be explicitly (re-)attached to
    /// each WKWebView's own WKUserContentController. Weak so a closed tab
    /// falls out of this registry on its own.
    static var liveTabsByProfile: [String: NSHashTable<WebKitTab>] = [:]

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

    /// A page-opened popup's tab, built from the configuration WebKit hands
    /// WKUIDelegate's createWebView -- see WebKitTab+UIDelegate.swift. It
    /// shares the opener's profile, and for a private tab its non-persistent
    /// data store, which is what a popup in the same browsing session needs.
    static func createPopupTab(configuration: WKWebViewConfiguration, openerProfileName: String) -> WebKitTab {
        let tab = WebKitTab(popupConfiguration: configuration, profileName: openerProfileName)
        register(tab, profileName: openerProfileName)
        return tab
    }

    private static func register(_ tab: WebKitTab, profileName: String) {
        let table = liveTabsByProfile[profileName] ?? NSHashTable<WebKitTab>.weakObjects()
        table.add(tab)
        liveTabsByProfile[profileName] = table
        if let ruleLists = compiledContentRuleLists[profileName] {
            tab.applyContentRuleLists(ruleLists)
        }
    }

    /// On CEF, -[BRWApplication terminate:] calls this handler before the
    /// engine shuts down, which is what saves the session at quit without
    /// waiting out its one-second debounce. WebKit has no terminate override,
    /// so the same handler runs from willTerminateNotification: every
    /// orderly quit posts it, and it arrives before the process exits with
    /// every window still open. isTerminating is raised first so closing the
    /// last window doesn't ask AppKit to terminate a second time.
    static func setWindowCloseHandler(_ handler: @escaping () -> Void) {
        windowCloseHandler = handler
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            guard !isTerminating else { return }
            isTerminating = true
            windowCloseHandler?()
        }
    }

    private static var terminationObserver: NSObjectProtocol?

    static func setBackgroundTabPolicy(_ policy: BackgroundTabPolicy) {
        WebKitBackgroundTabPolicy.current = policy
        for table in liveTabsByProfile.values {
            for tab in table.allObjects {
                WebKitBackgroundTabPolicy.apply(to: tab.webView.configuration.preferences)
            }
        }
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
    /// -download:decideDestinationUsing:... (WebKitTab+Downloads.swift) picks the path itself, so
    /// it just reads this instead of hardcoding ~/Downloads. That matters
    /// for the same reason as on CEF: an isolated `--profiles-root` test
    /// launch must not write into the real Downloads folder.
    static func setDownloadDirectory(_ path: String) {
        downloadDirectory = path
    }

    private(set) static var downloadDirectory = ""

    static func updateContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings]) {
        compileContentBlocking(domains: domains, profileSettings: profileSettings)
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
    /// threatInterstitialBuilder if it matches -- see
    /// WebKitTab+Navigation.swift.
    static func shouldWarn(host: String, profileName: String) -> Bool {
        guard !hasThreatSessionBypass(host: host, profileName: profileName) else { return false }
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
/// constraint); still not part of the engine's API surface --
/// nothing outside WebKitEngine ever sees a WebKitTab, only the EngineTab
/// protocol WebKitEngine.createTab(s) return.
final class WebKitTab: NSObject, EnginePopupTab {
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
    private let findFrames = WebKitFindFrameRegistry()
    let navigationState = WebKitNavigationState()
    let audioMute = WebKitAudioMute()
    let siteStyleSheets = WebKitSiteStyleSheets()
    /// Non-nil only while Responsive Design Mode is on.
    private(set) var responsiveDesign: WebKitResponsiveDesign?
    /// When "Peek Link" was last chosen -- see WebKitLinkPeekMenu.
    var linkPeekMenuArmedAt: Date?
    /// Shows a print operation as a sheet on the window and calls its closure
    /// once the sheet has gone. The adapter tests swap it out, since a real
    /// print panel would block the run loop they spin.
    var runPrintSheet: (NSPrintOperation, NSWindow, @escaping () -> Void) -> Void = WebKitTab.runPrintOperationSheet
    /// A window.print() that arrived mid-load, waiting for the load to end.
    var deferredPrint: WebKitDeferredPrint?

    private static let pageMessageHandlerName = "brwPageMessage"

    init(profileName: String, profileId: String, hostView: NSView, initialURL: String) {
        self.profileName = profileName
        var config = WKWebViewConfiguration()
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
        config.applicationNameForUserAgent = SafariUserAgent.applicationName
        if #available(macOS 15.4, *) {
            config = WebKitExtensionManager.shared.configuration(for: config, profileId: profileId, initialURL: initialURL)
        }
        webView = WebKitContentView(frame: hostView.bounds, configuration: config)
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
        config.applicationNameForUserAgent = SafariUserAgent.applicationName
        webView = WebKitContentView(frame: hostView.bounds, configuration: config)
        super.init()
        finishInit(hostView: hostView, initialURL: initialURL, config: config)
    }

    /// WebKit requires the returned web view to be built from exactly this
    /// configuration -- that is what links it to its opener. The copy it
    /// passes still shares the opener's WKUserContentController, though, and
    /// every tab installs its own named message handler there (a duplicate
    /// name throws) and removes it again on close (which would cut the
    /// opener off). So the popup gets a controller of its own.
    init(popupConfiguration config: WKWebViewConfiguration, profileName: String) {
        self.profileName = profileName
        config.userContentController = WKUserContentController()
        webView = WebKitContentView(frame: .zero, configuration: config)
        super.init()
        finishInit(hostView: nil, initialURL: nil, config: config)
    }

    func attach(to hostView: NSView) {
        webView.frame = hostView.bounds
        hostView.addSubview(webView)
    }

    /// `hostView`/`initialURL` are nil for a popup: it is attached later by
    /// whoever adopts it, and WebKit loads its first page itself.
    private func finishInit(hostView: NSView?, initialURL: String?, config: WKWebViewConfiguration) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = true
        installLinkPeekMenu()
        // Pinch is WebKit's visual magnification, on top of (not instead of)
        // the pageZoom the zoom menu drives -- the same split Safari has.
        // setZoomLevel(_:) resets it, so a zoom command always leaves the page
        // at exactly the level the UI reports.
        webView.allowsMagnification = true
        // `config` shares its WKPreferences object with the web view, so this
        // still takes effect after creation. Without it a video's fullscreen
        // button does nothing.
        if #available(macOS 12.3, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        // macOS defaults this to true, which lets a page open windows with no
        // user gesture at all. False makes WebKit's own popup blocker refuse
        // them before WKUIDelegate is ever asked; a click still opens one.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        WebKitBackgroundTabPolicy.apply(to: config.preferences)
        // Every tab is listed in Safari's Develop menu from the start, not
        // only once "Developer Tools" has been chosen for it.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        installPageMessageBridge(into: config.userContentController, handlerName: WebKitTab.pageMessageHandlerName)
        audioMute.install(into: config.userContentController)
        findFrames.install(into: config.userContentController)
        installDevTools()
        hostView?.addSubview(webView)

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
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.delegate?.engineTabDidUpdateLoadingProgress(webView.estimatedProgress)
        })
        observations.append(webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
            self?.delegate?.engineTabDidChangeSecurityState()
        })
        observations.append(webView.observe(\.serverTrust, options: [.new]) { [weak self] _, _ in
            self?.delegate?.engineTabDidChangeSecurityState()
        })
        // Favicons have no KVO/delegate hook on WKWebView; the navigation
        // delegate reads <link rel="icon"> itself when a load finishes.

        if let ruleLists = WebKitEngine.compiledContentRuleLists[profileName] {
            applyContentRuleLists(ruleLists)
        }

        if let initialURL { loadURL(initialURL) }
    }

    // MARK: - EngineTab

    /// A file URL only renders through loadFileURL(_:allowingReadAccessTo:),
    /// which hands the web content process a sandbox extension for the
    /// read-access directory; a plain load of one fails.
    func loadURL(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        if parsed.isFileURL {
            let fileURL = Self.resolvedFileURL(parsed)
            webView.loadFileURL(fileURL, allowingReadAccessTo: Self.fileReadAccessDirectory(for: fileURL))
        } else {
            webView.load(URLRequest(url: parsed))
        }
    }

    /// The directory a local page may read from. The grant has to be decided
    /// up front: when a file page links to a file outside it, WebKit refuses
    /// the navigation ("outside the sandbox") before the navigation delegate
    /// is consulted, so it cannot be caught and re-issued with a wider one.
    /// Chromium lets a file page embed and link to any other local file, so
    /// for a file under the user's home the grant is the whole home
    /// directory: relative links, `../` images and hops between the user's
    /// own documents all work, as they do on CEF. Outside home (/tmp, another
    /// volume) it is only the file's own directory -- granting the whole
    /// disk to a web content process is more than a local page needs, and a
    /// link from there to elsewhere on disk is the one case that fails.
    /// The wider grant does not let a page read files through script:
    /// fetch/XHR of file URLs stays off (allowFileAccessFromFileURLs is
    /// never set), exactly as in Chromium.
    static func fileReadAccessDirectory(for fileURL: URL) -> URL {
        let file = resolvedFileURL(fileURL)
        let home = resolvedFileURL(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        if isFile(file, inside: home) { return home }
        return file.hasDirectoryPath ? file : file.deletingLastPathComponent()
    }

    /// WebKit records the read-access directory after resolving it the way
    /// NSString's resolvingSymlinksInPath does, which strips a leading
    /// /private, and then requires the file's path to start with it
    /// verbatim. A file URL spelled /private/tmp/... is therefore refused as
    /// "outside the sandbox" unless it is resolved the same way first, so
    /// every file URL is loaded in its resolved spelling (file:///tmp/...).
    /// The query and fragment survive; only the path changes.
    static func resolvedFileURL(_ url: URL) -> URL {
        let path = (url.path as NSString).resolvingSymlinksInPath
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        }
        components.path = url.hasDirectoryPath && !path.hasSuffix("/") ? path + "/" : path
        return components.url ?? url
    }

    private static func isFile(_ file: URL, inside directory: URL) -> Bool {
        let directoryPath = resolvedFileURL(directory).path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return resolvedFileURL(file).path.hasPrefix(prefix)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if !retryFailedNavigationIfShowingErrorPage() { webView.reload() }
    }
    func close() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        deferredPrint = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebKitTab.pageMessageHandlerName)
        cancelPendingPageMessages()
        webView.removeFromSuperview()
    }

    /// The fallback for showDevTools(panel:dockSide:in:) when the in-app
    /// inspector SPI is missing on this macOS: isInspectable (set on every
    /// tab at creation) lets Safari's Develop menu attach to the tab, so a
    /// sheet explains where to find it and offers to open Safari.
    func showSafariInspectorHandOff() {
        NSLog("Browser: WebKit in-app Web Inspector unavailable -- showing the Safari Develop-menu hand-off instead")
        guard #available(macOS 13.3, *) else {
            unsupported("DevTools (Safari Web Inspector attachment needs macOS 13.3+)")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Inspect this page from Safari"
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Browser"
        alert.informativeText = """
        The WebKit engine has no built-in developer tools window. In Safari, choose \
        Develop > \(Host.current().localizedName ?? "this Mac") > \(appName), then pick this page.

        If Safari has no Develop menu, turn on "Show features for web developers" \
        in Safari Settings > Advanced.
        """
        alert.addButton(withTitle: "Open Safari")
        alert.addButton(withTitle: "OK")
        let openSafari = {
            guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
            NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
        }
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { openSafari() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            openSafari()
        }
    }
    /// Closes the in-app inspector. With the Safari fallback there is
    /// nothing to close: Safari's inspector window belongs to Safari.
    func closeDevTools() {
        WebKitInspectorSession.session(for: webView).close()
    }

    /// Built from private WKWebView SPI -- see WebKitResponsiveDesign.swift
    /// for what it reproduces of CEF's device-metrics override and what it
    /// cannot. Switching presets keeps the state captured on first entry.
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        if responsiveDesign == nil { responsiveDesign = WebKitResponsiveDesign(webView: webView) }
        guard let responsiveDesign else {
            unsupported("Responsive Design Mode (WKWebView layout/scale SPI missing on this macOS)")
            return
        }
        responsiveDesign.apply(width: width, height: height, deviceScaleFactor: deviceScaleFactor, mobile: mobile)
    }
    func clearResponsiveDesignMode() {
        responsiveDesign?.restore()
        responsiveDesign = nil
    }

    /// Private `_webProcessIdentifier` SPI, checked at runtime like this
    /// adapter's other SPI; nil when it is missing or no process is running.
    var contentProcessIdentifier: pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              pid > 0 else { return nil }
        return pid
    }

    func cpuUsagePercent() -> Double {
        unsupported("per-tab CPU usage (no CefTaskManager equivalent; WKWebView's renderer process stats aren't exposed publicly)")
        return 0
    }

    /// Best-effort and script-based. No public WKWebView API mutes page
    /// audio (WKWebExtensionTab's setMuted is for extension contexts only).
    /// See WebKitAudioMute for how it works and what can still be heard.
    func setAudioMuted(_ muted: Bool) {
        audioMute.setMuted(muted, in: webView)
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
        webView.magnification = 1
        webView.pageZoom = CGFloat(PageZoom.factor(forLevel: level))
    }

    func zoomLevel() -> Double {
        PageZoom.level(forFactor: Double(webView.pageZoom))
    }

    /// WebKit gets no say from this app on server trust (see
    /// WebKitTab+Navigation's authentication handler, which leaves it to
    /// WebKit's default handling), and that default refuses an untrusted
    /// certificate outright -- so a page that loaded never has a
    /// certificate error to report.
    ///
    /// Between a provisional start and its commit, webView.url is already
    /// the new address while serverTrust and hasOnlySecureContent still
    /// describe the old page, so nothing is reported until the commit.
    func securityStatus() -> EngineSecurityStatus? {
        guard !navigationState.isProvisional else { return nil }
        guard let scheme = webView.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let trust = webView.serverTrust
        return EngineSecurityStatus(
            isSecureConnection: scheme == "https" && trust != nil,
            hasCertificateError: false,
            hasInsecureContent: !webView.hasOnlySecureContent,
            serverTrust: trust)
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
    /// the ordinal from where WebKit's own selection landed, summed across
    /// the main frame and its iframes. When the selection is somewhere no
    /// walk can see (a form field), the ordinal is stepped from the previous
    /// result instead. Delivered
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

    /// One walk per frame. A frame whose walk fails (a removed iframe) or
    /// repeats another frame's position is dropped from the registry, and
    /// one that has not answered within a second is left out of this count
    /// only. The rest are ordered by frame path, which is the order WebKit's
    /// find steps through them, so the selected frame's ordinal is offset by
    /// every match in the frames before it.
    private func countFindMatches(_ query: String, matchCase: Bool, completion: @escaping (_ count: Int, _ selectedOrdinal: Int) -> Void) {
        struct FrameCount {
            let token: String?
            let count: Int
            let selectedOrdinal: Int
            let path: [Int]
            let visibilityState: String
            let isZeroSize: Bool
        }

        let targets: [(token: String?, frame: WKFrameInfo?)] = [(nil, nil)] + findFrames.frames.map { ($0.key, $0.value) }
        var results: [FrameCount] = []
        var failedTokens: [String] = []
        var pending = targets.count
        var finished = false
        var timedOut = false
        var mainFrameAnswered = false

        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            guard let self else { return }
            var frames: [FrameCount] = []
            var seenPaths: Set<[Int]> = []
            var duplicateTokens: [String] = []
            guard let main = results.first(where: { $0.token == nil }) else {
                self.findFrames.remove(tokens: failedTokens)
                completion(0, 0)
                return
            }
            for frame in [main] + results.filter({ $0.token != nil }) {
                if frame.token != nil, frame.isZeroSize || frame.visibilityState != main.visibilityState {
                    continue
                }
                guard seenPaths.insert(frame.path).inserted else {
                    if let token = frame.token { duplicateTokens.append(token) }
                    continue
                }
                frames.append(frame)
            }
            self.findFrames.remove(tokens: failedTokens + duplicateTokens)
            frames.sort { $0.path.lexicographicallyPrecedes($1.path) }

            let total = frames.reduce(0) { $0 + $1.count }
            let selected = frames.enumerated().filter { $0.element.selectedOrdinal > 0 }
            var ordinal = 0
            if selected.count == 1, let hit = selected.first {
                ordinal = frames[..<hit.offset].reduce(0) { $0 + $1.count } + hit.element.selectedOrdinal
            }
            completion(total, ordinal)
        }

        for target in targets {
            webView.callAsyncJavaScript(
                WebKitFindScript.countMatches,
                arguments: ["query": query, "matchCase": matchCase],
                in: target.frame,
                in: .defaultClient
            ) { result in
                guard !finished else { return }
                switch result {
                case .success(let value):
                    let parts = value as? [Any] ?? []
                    let number = { (index: Int) in parts.count > index ? (parts[index] as? NSNumber)?.intValue ?? 0 : 0 }
                    let path = (parts.count > 2 ? parts[2] as? [Any] : nil)?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                    results.append(FrameCount(
                        token: target.token,
                        count: number(0),
                        selectedOrdinal: number(1),
                        path: path,
                        visibilityState: parts.count > 3 ? parts[3] as? String ?? "" : "",
                        isZeroSize: parts.count > 4 ? (parts[4] as? NSNumber)?.boolValue ?? false : false
                    ))
                case .failure(let error):
                    if let token = target.token {
                        failedTokens.append(token)
                    } else {
                        NSLog("Browser: WebKit find match count failed: %@", error.localizedDescription)
                    }
                }
                pending -= 1
                if target.token == nil { mainFrameAnswered = true }
                if pending == 0 || (timedOut && mainFrameAnswered) { finish() }
            }
        }
        // An iframe that never answers must not hold the find bar's count
        // back; the main frame's own walk is always waited for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            timedOut = true
            if mainFrameAnswered { finish() }
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

    // No engineTabDidRequestVisualLookUp -- see setVisualLookUpAvailable's
    // doc comment for why it is missing.

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
let ActiveEngine: BrowserEngine.Type = CommandLineArgs.engineChoice().engine

extension EngineChoice {
    /// The conformer this choice launches -- for describing an engine that
    /// is not the running one (the Settings engine picker).
    var engine: BrowserEngine.Type {
        switch self {
        case .cef: return CEFEngine.self
        case .webkit: return WebKitEngine.self
        }
    }
}
