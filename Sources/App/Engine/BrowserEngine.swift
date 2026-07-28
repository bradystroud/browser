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

/// Per-tab navigation/state/download/permission callbacks -- the
/// engine-agnostic counterpart of the bridge's BRWBrowserDelegate
/// (Objective-C protocol, CEF-specific naming). One EngineTab has at most
/// one delegate.
protocol EngineTabDelegate: AnyObject {
    func engineTabDidChangeTitle(_ title: String)
    func engineTabDidChangeURL(_ url: String)
    func engineTabDidChangeFaviconURL(_ faviconURL: String?)
    func engineTabDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool)

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
    /// -browserDidReceivePageMessage:requestId: for the exact contract,
    /// including that `requestId` must eventually reach
    /// respondToPageMessage(requestId:success:response:) below exactly once
    /// or the page's promise never resolves.
    func engineTabDidReceivePageMessage(_ request: String, requestId: Int64)

    /// Fires once per top-level navigation at "document-start" timing --
    /// see BRWBrowser.h's -browserDidStartMainFrameLoad for the exact CEF
    /// guarantee (after commit, before the new document's own scripts run).
    /// The right moment to executeJavaScript(_:) a script that needs to run
    /// before the page's own code does.
    func engineTabDidStartMainFrameLoad()
}

/// One tab's engine-side browser surface -- the engine-agnostic counterpart
/// of whatever concrete rendering engine backs it. UI code (Tab.swift and
/// everything above it) programs against this protocol only, never against
/// an engine-specific type, per AGENTS.md's engine-agnostic-UI principle.
/// Today's only conformer is CEFTab (Sources/App/Engine/CEFEngineAdapter.swift),
/// a thin wrapper around the bridge's BRWBrowser.
protocol EngineTab: AnyObject {
    var delegate: EngineTabDelegate? { get set }
    func loadURL(_ url: String)
    func goBack()
    func goForward()
    func reload()
    func close()
    func showDevTools()
    func closeDevTools()

    /// Overrides this tab's viewport to a fixed device size/scale, the same
    /// effect as DevTools' own device toolbar (browser-6hi.2) -- see
    /// BRWBrowser.h's -setResponsiveDesignModeWithWidth:... for why this
    /// works without opening DevTools' own UI at all.
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool)

    /// Turns off any override set by setResponsiveDesignMode(...) -- safe to
    /// call even if none is currently active.
    func clearResponsiveDesignMode()

    /// Mutes/unmutes this tab's audio output (browser-rhi.4) -- see
    /// BRWBrowser.h's -setAudioMuted: for why this is a real, direct CEF
    /// call rather than a JS workaround.
    func setAudioMuted(_ muted: Bool)

    /// Mirrors the engine's own current mute state -- see BRWBrowser.h's
    /// -isAudioMuted.
    func isAudioMuted() -> Bool

    /// Opens the engine's native print dialog for this tab's current page --
    /// see BRWBrowser.h's -print for what "native" actually means in this
    /// Alloy-style app (browser-5kq.6).
    func print()

    /// Exports the current page to a PDF at `path` with the engine's default
    /// print settings -- see BRWBrowser.h's -printToPDFWithPath:completion:
    /// for exactly what's left at defaults. `completion` runs exactly once,
    /// on the main thread, with whether it succeeded and the same `path` back.
    func printToPDF(path: String, completion: @escaping (Bool, String) -> Void)

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

    /// Retrieves the current page's serialized HTML source -- see
    /// BRWBrowser.h's -getPageSourceWithCompletion: for the real, native CEF
    /// API this wraps and why it exists alongside the fire-and-forget
    /// executeJavaScript(_:) above.
    func getPageSource(completion: @escaping (String?) -> Void)

    /// Answers a page message previously delivered via
    /// engineTabDidReceivePageMessage(_:requestId:) -- see BRWBrowser.h's
    /// -respondToPageMessageWithId:success:response: for the exact contract
    /// (in particular, that `requestId` is global across every tab, not
    /// scoped to whichever EngineTab this is called on).
    func respondToPageMessage(requestId: Int64, success: Bool, response: String)
}

/// Process-wide engine lifecycle + tab creation. A protocol with static
/// requirements (conformed to by exactly one concrete adapter at a time,
/// referenced everywhere else as `ActiveEngine`) rather than an instance
/// type, since the underlying engine API this wraps is itself entirely
/// static/class-level -- one engine process per app, not a per-window or
/// per-tab instance.
///
/// Today's only conformer is CEFEngine
/// (Sources/App/Engine/CEFEngineAdapter.swift), a thin wrapper around the
/// bridge's BRWEngine/BRWApplication. Swapping engines (e.g. a future WebKit
/// backend, see AGENTS.md) means adding a new conformer there and changing
/// `ActiveEngine`'s typealias target -- nothing in Sources/App outside that
/// one file should need to change.
protocol BrowserEngine {
    /// Must run before anything touches NSApplication.shared -- see
    /// main.swift and the CEF adapter's own doc comment for why.
    static func bootstrapApplication()

    static func initialize(profilesRootPath: String) -> Bool

    static func createTab(profileName: String, hostView: NSView, initialURL: String) -> EngineTab

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
}
