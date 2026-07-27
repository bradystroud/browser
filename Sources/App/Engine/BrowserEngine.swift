import AppKit

/// Per-tab navigation/state/download callbacks -- the engine-agnostic
/// counterpart of the bridge's BRWBrowserDelegate (Objective-C protocol,
/// CEF-specific naming). One EngineTab has at most one delegate.
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

    /// Registers the block the app uses to close every window it owns as
    /// part of quitting -- see the CEF adapter for why this ordering matters
    /// for a CEF-backed engine specifically.
    static func setWindowCloseHandler(_ handler: @escaping () -> Void)

    /// Whether the engine's own termination sequence (see
    /// setWindowCloseHandler) is currently in progress.
    static var isTerminating: Bool { get }
}
