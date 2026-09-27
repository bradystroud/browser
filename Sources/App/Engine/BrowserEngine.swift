import AppKit

/// A small, engine-agnostic bitmask of permission kinds this app's UI
/// actually prompts for -- mirrors BRWPermissionKind (BRWBrowser.h) 1:1; see
/// CEFEngineAdapter.swift's translation and BRWClientHandler.mm's own
/// translation from CEF's much larger permission type enums. Only what
/// browser-12m.2 covers: camera, microphone, geolocation, notifications.
struct EnginePermissionKind: OptionSet {
    let rawValue: Int
    static let camera = EnginePermissionKind(rawValue: 1 << 0)
    static let microphone = EnginePermissionKind(rawValue: 1 << 1)
    static let geolocation = EnginePermissionKind(rawValue: 1 << 2)
    static let notifications = EnginePermissionKind(rawValue: 1 << 3)
}

/// Mirrors BRWWindowOpenDisposition (BRWBrowser.h) 1:1 -- see
/// CEFEngineAdapter.swift's translation and
/// EngineTabDelegate.engineTabDidRequestNewTab's own doc comment.
enum EngineWindowOpenDisposition {
    case foregroundTab
    case backgroundTab
    case newWindow
    case newPopup
}

/// Which developer-tools panel to bring forward when opening them. Engines
/// that cannot select a panel open whatever they last showed.
enum DevToolsPanel {
    /// Whatever the tools last showed (Elements the first time).
    case `default`
    case console
    case elements
}

/// Where a tab's developer tools live. Bottom/right/left dock them into the
/// tab's own content area; `window` is the engine's own separate window.
enum DevToolsDockSide: String, CaseIterable {
    case bottom
    case right
    case left
    case window
}

/// Per-tab navigation/state/download/permission callbacks -- the
/// engine-agnostic counterpart of the bridge's BRWBrowserDelegate
/// (Objective-C protocol, CEF-specific naming). One EngineTab has at most
/// one delegate.
protocol EngineTabDelegate: AnyObject {
    func engineTabDidChangeTitle(_ title: String)
    func engineTabDidChangeURL(_ url: String)
    func engineTabDidChangeFaviconURL(_ faviconURL: String?)
    func engineTabDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool)

    /// Fires as soon as a main-frame navigation is requested, before it
    /// commits (browser-7z5) -- see BRWBrowser.h's
    /// -browserWillStartMainFrameNavigationTo: for the exact CEF timing
    /// (OnBeforeBrowse, the earliest point a navigation can be observed).
    /// The optimistic-UI signal: a click should show feedback instantly,
    /// not wait for the real navigation to actually commit.
    func engineTabWillStartMainFrameNavigation(_ url: String)

    /// Overall page-loading progress, 0.0-1.0 -- see BRWBrowser.h's
    /// -browserDidUpdateLoadingProgress: for the real CEF signal this
    /// mirrors (a genuine percentage, not a fake/eased approximation).
    func engineTabDidUpdateLoadingProgress(_ progress: Double)

    /// Fired once per successfully-completed top-level (main-frame)
    /// navigation -- see BRWBrowser.h's -browserDidCommitNavigation: (which
    /// this mirrors) for exactly what counts. This is the history-recording
    /// signal -- see Tab.swift / BrowserWindowController.
    func engineTabDidCommitNavigation(_ url: String)

    func engineTabDidBeginDownload(id: Int64, url: String, suggestedName: String, destinationPath: String)
    func engineTabDidUpdateDownload(id: Int64, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCancelled: Bool, isInterrupted: Bool)

    /// A page at `requestingOrigin` wants permission for `kinds` (e.g.
    /// camera and microphone together, for one getUserMedia call -- see
    /// BRWBrowser.h's -browserDidRequestPermission:... for why a bundled
    /// media request is always one combined ask). `promptId` correlates
    /// with a later `engineTabDidDismissPermissionRequest` if the request
    /// goes away before the user answers. Call `decision` at most once, on
    /// the main thread, with true to allow or false to deny -- never after
    /// a matching dismiss for the same `promptId`.
    func engineTabDidRequestPermission(_ kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void)

    /// The request identified by `promptId` no longer needs an answer --
    /// see BRWBrowser.h's -browserDidDismissPermissionRequest:.
    func engineTabDidDismissPermissionRequest(_ promptId: UInt64)

    /// Result update for a search started via find(_:forward:matchCase:
    /// findNext:) -- see BRWBrowser.h's -browserDidUpdateFindResultWithMatchCount:...
    /// for the exact semantics (delivered repeatedly, not just once).
    func engineTabDidUpdateFindResult(matchCount: Int, activeMatchOrdinal: Int, isFinalUpdate: Bool)

    /// A page called `window.cefQuery({request: ...})` via the generic
    /// JS<->native channel (browser-ojh.1) -- see BRWBrowser.h's
    /// -browserDidReceivePageMessage:requestId:isMainFrame:frameURL: for the exact contract,
    /// including that `requestId` must eventually reach
    /// respondToPageMessage(requestId:success:response:) below exactly once
    /// or the page's promise never resolves. `source` is the engine's own
    /// account of which frame sent it -- the only part of a page message
    /// that can be trusted (see PageMessagePolicy).
    func engineTabDidReceivePageMessage(_ request: String, requestId: Int64, source: PageMessageSource)

    /// Fires once per top-level navigation at "document-start" timing --
    /// see BRWBrowser.h's -browserDidStartMainFrameLoadWithURL: for the exact CEF
    /// guarantee (after commit, before the new document's own scripts run).
    /// The right moment to executeJavaScript(_:) a script that needs to run
    /// before the page's own code does.
    func engineTabDidStartMainFrameLoad()

    /// The user chose "Look Up Image" from the native context menu over an
    /// image (browser-5kq.2) -- see BRWBrowser.h's
    /// -browserDidRequestVisualLookUpForImageURL:pageURL: for what `imageURL`/
    /// `pageURL` actually are.
    func engineTabDidRequestVisualLookUp(imageURL: String, pageURL: String)

    /// The user chose "View Page Source" from the native context menu -- see
    /// BRWBrowser.h's -browserDidRequestViewSourceForPageURL: for why this is
    /// a callback the shell answers rather than something the engine does
    /// for itself. The handler is expected to open the page's source in a
    /// new tab.
    func engineTabDidRequestViewSource(pageURL: String)

    /// The user chose "Copy Image" from the native context menu over an image
    /// (browser-5kq.13) -- see BRWBrowser.h's
    /// -browserDidRequestCopyImageForImageURL:pageURL:. The handler is
    /// expected to get the bytes via EngineTab.downloadImage(url:completion:)
    /// on the same tab, not by fetching `imageURL` itself.
    func engineTabDidRequestCopyImage(imageURL: String, pageURL: String)

    /// The user chose "Copy Image Link" from the native context menu over an
    /// image (browser-5kq.13) -- `imageURL` is the image's own source URL,
    /// the only thing this command needs.
    func engineTabDidRequestCopyImageLink(imageURL: String)

    /// The user chose "Download Image" from the native context menu over an
    /// image (browser-5kq.14) -- see BRWBrowser.h's
    /// -browserDidRequestDownloadImageForImageURL:. Handled by starting a
    /// real engine download (EngineTab.startDownload(url:)) so it flows
    /// through the same DownloadCoordinator/DownloadStore path as any
    /// page-initiated download, rather than writing bytes to disk privately.
    func engineTabDidRequestDownloadImage(imageURL: String)

    /// The engine wants `url` opened somewhere other than the current tab --
    /// either because the page asked for a new browsing context (a
    /// target="_blank" link or window.open() call) or because the user
    /// Cmd/Cmd+Shift/Shift/middle-clicked an ordinary <a href>. The
    /// disposition already accounts for the click's modifiers; see
    /// BRWBrowser.h's -browserDidRequestNewTabForURL:disposition: for the
    /// full contract and the two distinct CEF callbacks behind it.
    func engineTabDidRequestNewTab(url: String, disposition: EngineWindowOpenDisposition)

    /// The page opened a new browsing context (window.open() or a
    /// target="_blank" link) and the engine created the new tab itself,
    /// already linked to this one -- so the popup's `window.opener` is set
    /// and it can postMessage back, which OAuth sign-in flows depend on.
    /// The receiver must adopt `popup` synchronously (keep a strong
    /// reference and attach it to a host view) or it is lost. Engines that
    /// can only reopen a popup by URL use engineTabDidRequestNewTab instead.
    func engineTabDidCreatePopup(_ popup: EnginePopupTab, disposition: EngineWindowOpenDisposition)

    /// The page called window.close() and the engine allowed it (engines
    /// only allow it for a script-opened window, or one with a single
    /// history entry). Closes this one tab -- never its whole window, which
    /// may hold other tabs.
    func engineTabDidRequestClose()

    /// The content blocker cancelled a resource request to an ad/tracker
    /// domain -- see BRWBrowser.h's
    /// -browserDidBlockRequestToTracker:onPageHost: for the exact CEF-side
    /// signal this mirrors. Fired once per blocked request; the toolbar
    /// badge's count is a running tally of these.
    ///
    /// `trackerDomain` is the block list entry that matched, not the
    /// request's own host, so one tracker's many subdomains report as one
    /// tracker. `pageHost` is the tab's main-frame host captured at the
    /// moment of the block rather than when this arrives, so a block that
    /// lands after the next navigation started is still attributed to the
    /// page that actually made it (browser-e7r). Either may be empty when
    /// the underlying URL had no parseable host.
    func engineTabDidBlockRequest(trackerDomain: String, pageHost: String)

    /// The engine opened this tab's developer tools on its own -- from its
    /// own context menu's Inspect Element, say -- rather than because
    /// showDevTools(panel:dockSide:in:) was called. Delivered before the tools are
    /// placed anywhere, so the receiver can call showDevTools(panel:dockSide:in:)
    /// from inside this callback to claim them for its dock container.
    /// Also delivered, harmlessly, for opens the receiver asked for itself.
    func engineTabDevToolsDidOpen()

    /// This tab's developer tools closed, including from their own UI
    /// (the close button, or closing their separate window).
    func engineTabDevToolsDidClose()

    /// The user picked a dock side from inside the developer tools' own UI.
    /// The receiver should move its dock container to match; the tools
    /// themselves have already moved.
    func engineTabDevToolsDidRequestDockSide(_ side: DevToolsDockSide)

    /// The user chose the engine's own context-menu Inspect Element at
    /// `point` (in the tab's web content view's coordinates). The receiver
    /// opens the tools where it wants them and answers with
    /// inspectElement(at:), passing `point` unchanged. An engine that claims
    /// its tools through engineTabDevToolsDidOpen() instead never sends it.
    func engineTabDidRequestInspectElement(at point: NSPoint)
}

/// One tab's engine-side browser surface -- the engine-agnostic counterpart
/// of whatever concrete rendering engine backs it. UI code (Tab.swift and
/// everything above it) programs against this protocol only, never against
/// an engine-specific type, per AGENTS.md's engine-agnostic-UI principle.
/// Conformers: CEFTab (Sources/App/Engine/CEFEngineAdapter.swift), a thin
/// wrapper around the bridge's BRWBrowser, and WebKitTab
/// (Sources/App/Engine/WebKitEngineAdapter.swift), a WKWebView wrapper.
extension Notification.Name {
    /// Posted with the EngineTab as `object` when the process rendering its
    /// page ends -- a crash, or the system reclaiming a hidden tab's memory.
    static let engineTabContentProcessDidTerminate = Notification.Name("EngineTabContentProcessDidTerminate")
}

protocol EngineTab: AnyObject {
    var delegate: EngineTabDelegate? { get set }
    /// The process rendering this tab's page, for memory diagnostics. Nil
    /// when the engine can't say (CEF), or the tab has no process yet.
    var contentProcessIdentifier: pid_t? { get }
    func loadURL(_ url: String)
    func goBack()
    func goForward()
    func reload()
    func close()

    /// Opens (or brings forward) this tab's developer tools on `panel`, or
    /// moves already-open tools. `container` is the view docked tools must
    /// fill, owned and laid out by the app: the engine never sizes the page
    /// itself. `dockSide` says where that container sits relative to the
    /// page, for the tools' own dock-side controls; `.window` (or a nil
    /// container) means the engine's own separate window. An engine without
    /// EngineCapabilities.devToolsDocking ignores both and always uses its
    /// own window.
    func showDevTools(panel: DevToolsPanel, dockSide: DevToolsDockSide, in container: NSView?)

    /// Closes this tab's developer tools, docked or not. Safe when closed.
    func closeDevTools()

    /// Whether this tab's developer tools are open, as far as the engine
    /// knows -- including while they are still loading.
    var isDevToolsOpen: Bool { get }

    /// Turns on the tools' element picker, so the next click on the page
    /// selects that element in the Elements panel. Call after
    /// showDevTools(panel:dockSide:in:); an engine without a picker just shows the
    /// Elements panel.
    func startElementPicker()

    /// Reveals the element at `point` (in the tab's web content view's own
    /// coordinates, as a context-menu click reports it) in the Elements
    /// panel. Call after showDevTools(panel:dockSide:in:).
    func inspectElement(at point: NSPoint)

    /// Overrides this tab's viewport to a fixed device size/scale, the same
    /// effect as DevTools' own device toolbar (browser-6hi.2) -- see
    /// BRWBrowser.h's -setResponsiveDesignModeWithWidth:... for why this
    /// works without opening DevTools' own UI at all.
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool)

    /// Turns off any override set by setResponsiveDesignMode(...) -- safe to
    /// call even if none is currently active.
    func clearResponsiveDesignMode()

    /// This tab's current CPU usage as a percentage of one core
    /// (browser-7jz.4) -- see BRWBrowser.h's -cpuUsagePercent for the real
    /// CefTaskManager-backed mechanism and why 0 is the safe default.
    func cpuUsagePercent() -> Double

    /// Mutes/unmutes this tab's audio output (browser-rhi.4) -- see
    /// BRWBrowser.h's -setAudioMuted: for why this is a real, direct CEF
    /// call rather than a JS workaround.
    func setAudioMuted(_ muted: Bool)

    /// Sets this tab's page zoom (browser-5kq.15). `level` is Chromium's
    /// *logarithmic* zoom level, not a percentage: the on-screen scale factor
    /// is pow(1.2, level), so 0 is exactly 100%. Use PageZoom (PageZoom.swift)
    /// to convert between a human-facing factor and this level rather than
    /// doing the arithmetic at a call site. See BRWBrowser.h's -setZoomLevel:.
    ///
    /// How far a zoom *spreads* is an engine property, not a guarantee of this
    /// protocol, and the two current conformers genuinely differ: CEF scopes it
    /// per host per profile (measured -- see BRWBrowser.h's -setZoomLevel:,
    /// which is why Tab never caches a factor), WKWebView's pageZoom is per web
    /// view. Callers must therefore treat zoomLevel() below as the only source
    /// of truth for "what is this tab at right now".
    func setZoomLevel(_ level: Double)

    /// Reads back the engine's own current zoom level for this tab, in the
    /// same logarithmic units setZoomLevel(_:) takes -- see BRWBrowser.h's
    /// -zoomLevel. 0 (i.e. 100%) when there's no engine-side browser yet.
    func zoomLevel() -> Double

    /// Opens the engine's native print dialog for this tab's current page --
    /// see BRWBrowser.h's -print for what "native" actually means in this
    /// Alloy-style app (browser-5kq.6).
    func print()

    /// Exports the current page to a PDF at `path` with the engine's default
    /// print settings -- see BRWBrowser.h's -printToPDFWithPath:completion:
    /// for exactly what's left at defaults. `completion` runs exactly once,
    /// on the main thread, with whether it succeeded and the same `path` back.
    func printToPDF(path: String, completion: @escaping (Bool, String) -> Void)

    /// Fetches and decodes the image at `url` through *this tab's* own
    /// engine-side network stack, yielding PNG bytes -- see BRWBrowser.h's
    /// -downloadImageAtURL:completion: for why this is not interchangeable
    /// with a URLSession fetch of the same URL (the page's cookies), and for
    /// what the decode step does to animated/undecodable formats.
    /// `completion` runs exactly once, on the main thread; `pngData` is nil
    /// on any failure.
    func downloadImage(url: String, completion: @escaping (_ pngData: Data?, _ httpStatusCode: Int) -> Void)

    /// Starts a real, user-visible download of `url` originating from this
    /// tab -- see BRWBrowser.h's -startDownloadForURL: for why this reaches
    /// the same engineTabDidBeginDownload/engineTabDidUpdateDownload
    /// callbacks a page-initiated download does, which is the entire point
    /// (browser-5kq.14). Fire-and-forget; progress and failure arrive
    /// through those callbacks, not a completion block.
    func startDownload(url: String)

    /// Searches the current page -- see BRWBrowser.h's -find:forward:
    /// matchCase:findNext: for CEF's exact semantics (browser-5kq.5).
    /// Results arrive via EngineTabDelegate.engineTabDidUpdateFindResult.
    func find(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool)

    /// Cancels any in-progress search -- see BRWBrowser.h's -stopFinding:.
    func stopFinding(clearSelection: Bool)

    /// Executes `code` as JavaScript, fire-and-forget -- see BRWBrowser.h's
    /// -executeJavaScript: for why this genuinely has no result path at all
    /// (browser-5kq.1).
    func executeJavaScript(_ code: String)

    /// Stylesheets keyed by site (a registrable domain such as
    /// `example.com`, covering its subdomains too). Every main-frame document
    /// this tab loads from then on gets its site's sheet from document start,
    /// before first paint wherever the engine can promise that; the current
    /// document is updated straight away. Replaces any earlier call's map --
    /// pass [:] to remove them all. See SiteStyleSheetScript.
    func setSiteStyleSheets(_ sheetsBySite: [String: String])

    /// Retrieves the current page's serialized HTML source -- see
    /// BRWBrowser.h's -getPageSourceWithCompletion: for the real, native CEF
    /// API this wraps and why it exists alongside the fire-and-forget
    /// executeJavaScript(_:) above.
    func getPageSource(completion: @escaping (String?) -> Void)

    /// Answers a page message previously delivered via
    /// engineTabDidReceivePageMessage(_:requestId:source:) -- see BRWBrowser.h's
    /// -respondToPageMessageWithId:success:response: for the exact contract
    /// (in particular, that `requestId` is global across every tab, not
    /// scoped to whichever EngineTab this is called on).
    func respondToPageMessage(requestId: Int64, success: Bool, response: String)
}

/// A tab the engine created on its own for a page-opened popup, before it
/// has anywhere to draw -- see EngineTabDelegate.engineTabDidCreatePopup.
protocol EnginePopupTab: EngineTab {
    /// Puts the tab's view into `hostView`, sized to fill it and tracking
    /// its size from then on. Called once, by whoever adopts the popup.
    func attach(to hostView: NSView)
}

/// What the running engine can actually do, for UI that would otherwise
/// offer a command the engine cannot carry out. UI reads
/// `ActiveEngine.capabilities` rather than asking which engine is running.
struct EngineCapabilities {
    /// A developer-tools window opened from inside the app, including
    /// right-click Inspect Element. When false, showDevTools(panel:dockSide:in:)
    /// explains how to inspect the page from another app instead.
    var inAppDevTools: Bool
    /// showDevTools(panel:dockSide:in:) puts docked tools into the container
    /// it is given. When false the engine always uses its own window, so the
    /// app offers no dock sides.
    var devToolsDocking: Bool = false
    /// Docked tools draw their own dock-side and close controls. When false
    /// (CEF's embedded front-end runs without any), the app's dock pane adds
    /// a header bar carrying them.
    var devToolsHasOwnChrome: Bool = false
    /// setResponsiveDesignMode(...) actually resizes the viewport.
    var responsiveDesignMode: Bool
    /// cpuUsagePercent() reports a real per-tab figure rather than 0.
    var perTabCPUUsage: Bool
    /// setAudioMuted(_:) silences just that tab.
    var perTabAudioMute: Bool
    /// The native context menu carries this app's own items (Look Up Image,
    /// Copy Image, View Page Source and so on).
    var customContextMenuItems: Bool
    /// setBackgroundTabPolicy(_:) changes how hidden tabs are treated. When
    /// false the engine has no such control, and the setting is not offered.
    var backgroundTabPolicy: Bool = false
}

/// How hard the engine works to save memory in tabs the user can't see.
/// Ordered from most memory saved to most responsive.
enum BackgroundTabPolicy: String, CaseIterable {
    /// Hidden tabs stop running. The system can reclaim their memory, and
    /// a reclaimed tab reloads when it is shown again.
    case saveMemory
    /// Hidden tabs keep running at a reduced rate and stay loaded.
    case balanced
    /// Hidden tabs run as if they were visible.
    case keepReady
}

/// Which BrowserEngine conformer `--engine` (see CommandLineArgs.engineChoice())
/// selects at launch. Exhaustive by design -- adding a third engine means
/// updating this enum, its one switch in WebKitEngineAdapter.swift's
/// `ActiveEngine`, and nothing else in Sources/App.
enum EngineChoice {
    case cef
    case webkit
}

/// One profile's content-blocking configuration -- the engine-agnostic
/// counterpart of the bridge's BRWProfileBlockingSettings (BRWContentBlocker.h),
/// itself a thin carrier for BlockListCore's BlockingSettings. Exists so
/// ContentBlockerCoordinator (Sources/App/Blocking) never needs to import a
/// BRW* bridge type directly -- see AGENTS.md's engine-agnostic-UI principle.
struct EngineProfileBlockingSettings {
    let enabled: Bool
    let allowlistedHosts: [String]
}

/// One profile's threat-warning configuration -- the engine-agnostic
/// counterpart of the bridge's BRWProfileThreatSettings (BRWThreatList.h).
struct EngineProfileThreatSettings {
    let enabled: Bool
}

/// Process-wide engine lifecycle + tab creation. A protocol with static
/// requirements (conformed to by exactly one concrete adapter at a time,
/// referenced everywhere else as `ActiveEngine`) rather than an instance
/// type, since the underlying engine API this wraps is itself entirely
/// static/class-level -- one engine process per app, not a per-window or
/// per-tab instance.
///
/// Conformers: CEFEngine (Sources/App/Engine/CEFEngineAdapter.swift), a thin
/// wrapper around the bridge's BRWEngine/BRWApplication, and WebKitEngine
/// (Sources/App/Engine/WebKitEngineAdapter.swift). `ActiveEngine` picks one
/// at launch from `--engine cef|webkit` -- nothing in Sources/App outside
/// Engine/ should need to know which.
protocol BrowserEngine {
    /// Must run before anything touches NSApplication.shared -- see
    /// main.swift and the CEF adapter's own doc comment for why.
    static func bootstrapApplication()

    /// Read at the point of use rather than cached: a capability may only
    /// become known at runtime.
    static var capabilities: EngineCapabilities { get }

    static func initialize(profilesRootPath: String) -> Bool

    /// `profileId` (the profile's stable UUID) is what actually scopes the
    /// engine-side cache/storage directory (browser-ojw) -- keyed by id, not
    /// `profileName`, so a later profile rename never needs to move it or
    /// leave an already-open tab pointing at stale storage. `profileName` is
    /// kept only for name-keyed, in-memory-only mechanisms (content-blocking
    /// snapshot lookups) that a rename simply rebuilds fresh -- see the CEF
    /// adapter/BRWBrowser.h for exactly where each is used.
    static func createTab(profileName: String, profileId: String, hostView: NSView, initialURL: String) -> EngineTab

    /// Creates a tab for a Private Browsing window (browser-12m.1): backed by
    /// an engine context with no persisted profile identity at all -- not
    /// just an empty/throwaway `profileName`, an actually distinct in-memory
    /// context per call, so no two private tabs (even in the same window)
    /// share cookies/storage with each other or with any real profile. See
    /// the CEF adapter for exactly what "in-memory" means for CEF.
    static func createPrivateTab(hostView: NSView, initialURL: String) -> EngineTab

    /// Registers the block the app uses to close every window it owns as
    /// part of quitting -- see the CEF adapter for why this ordering matters
    /// for a CEF-backed engine specifically.
    static func setWindowCloseHandler(_ handler: @escaping () -> Void)

    /// Whether the engine's own termination sequence (see
    /// setWindowCloseHandler) is currently in progress.
    static var isTerminating: Bool { get }

    /// Whether every browser's context menu should offer "Look Up Image"
    /// over an image (browser-5kq.2) -- see BRWBrowser.h's
    /// +setVisualLookUpAvailable: for why this is process-wide rather than
    /// per-tab. Call once, before creating the first tab, with whatever
    /// VisionKit.ImageAnalyzer.isSupported reports.
    static func setVisualLookUpAvailable(_ available: Bool)

    /// Applies to every open tab and every tab created afterwards. A no-op
    /// when `capabilities.backgroundTabPolicy` is false.
    static func setBackgroundTabPolicy(_ policy: BackgroundTabPolicy)

    /// Where completed downloads are written (browser-5kq.14) -- process-
    /// wide, set once at launch before any tab exists. See BrowserCore's
    /// `ProfilesRootResolver.downloadsDirectory` for the rule: the user's
    /// real `~/Downloads` normally, contained under an explicit
    /// `--profiles-root` when one was passed, so an isolated test launch
    /// can't drop files into the real Downloads folder.
    static func setDownloadDirectory(_ path: String)

    /// Publishes a fresh content-blocking snapshot -- the shared blocked-
    /// domain list plus every existing profile's settings -- for the engine
    /// to enforce on its own resource-load path (browser-12m.5.1). See the
    /// CEF adapter for the exact atomic-swap contract this wraps
    /// (BRWContentBlocker.h's +updateWithBlockedDomains:profileSettings:).
    /// Call from the main thread at launch and any time the shared list or
    /// a profile's BlockingSettings changes -- see ContentBlockerCoordinator.
    static func updateContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings])

    /// Registers the Swift closure that renders a blocked-navigation warning
    /// page for a given host and the original URL that was blocked
    /// (browser-12m.6) -- see the CEF adapter for the exact contract
    /// (BRWThreatList.h's +setInterstitialPageBuilder:). Call once, from the
    /// main thread, before any tab can navigate -- see ThreatListCoordinator.start().
    static func setThreatInterstitialBuilder(_ builder: @escaping (_ host: String, _ originalURL: String) -> String)

    /// Publishes a fresh threat-warning snapshot -- the shared threat-domain
    /// list plus every existing profile's settings (browser-12m.6). See the
    /// CEF adapter for the exact contract (BRWThreatList.h's
    /// +updateWithThreatDomains:profileSettings:). Call from the main thread
    /// at launch and any time the shared list or a profile's
    /// ThreatWarningSettings changes -- see ThreatListCoordinator.
    static func updateThreatBlocking(domains: [String], profileSettings: [String: EngineProfileThreatSettings])
}
