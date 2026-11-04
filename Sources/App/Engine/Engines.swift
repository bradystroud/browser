import AppKit

/// Both rendering engines, running side by side in this one process, and
/// the only way anything outside Engine/ reaches either.
///
/// Why one process can hold both: CEF here is an external-pump embedder.
/// `BRWMessagePump` drives `CefDoMessageLoopWork()` from main-queue blocks
/// and run-loop timers on the ordinary main run loop, and WKWebView is an
/// in-process NSView whose web content, networking and GPU work live in
/// WebKit's own XPC processes and reach the UI process through the same
/// run loop. Neither replaces the other's loop, and neither cares which
/// NSApplication subclass is running. What must be shared is decided here:
///
/// - `NSApp` is CEF's `BRWApplication`, always. CEF needs it installed
///   before anything touches `NSApplication.shared`; WebKit needs no
///   subclass at all and runs under it unchanged.
/// - Quitting is CEF's: `-[BRWApplication terminate:]` closes every window
///   (WebKit tabs included) through the window close handler, waits for
///   CEF's browsers to finish closing, posts AppKit's
///   `willTerminateNotification` itself, then exits. WebKit's own quit hook
///   (which closes windows from that notification) is not registered: the
///   windows are already closed by then.
/// - Every process-wide setting (downloads folder, blocking lists, threat
///   lists, background-tab policy) goes to both engines.
/// - Extensions are WebKit's only; CEF 150 Alloy has none.
enum Engines {
    static func engine(_ choice: EngineChoice) -> BrowserEngine.Type {
        switch choice {
        case .cef: return CEFEngine.self
        case .webkit: return WebKitEngine.self
        }
    }

    /// What `choice` can do. Read at the point of use: a capability may
    /// only become known at runtime.
    static func capabilities(for choice: EngineChoice) -> EngineCapabilities {
        engine(choice).capabilities
    }

    /// Whether either engine can do something, for process-wide UI (a menu
    /// that only makes sense if some tab could use it).
    static func anyEngine(_ capability: (EngineCapabilities) -> Bool) -> Bool {
        EngineChoice.allCases.contains { capability(capabilities(for: $0)) }
    }

    /// Must run before anything touches NSApplication.shared.
    static func bootstrapApplication() {
        CEFEngine.bootstrapApplication()
    }

    /// Both or nothing: a tab of either engine can open at any time.
    static func initialize(profilesRootPath: String) -> Bool {
        EngineChoice.allCases.allSatisfy { engine($0).initialize(profilesRootPath: profilesRootPath) }
    }

    static func createTab(engine choice: EngineChoice, profileName: String, profileId: String, hostView: NSView, initialURL: String) -> EngineTab {
        engine(choice).createTab(profileName: profileName, profileId: profileId, hostView: hostView, initialURL: initialURL)
    }

    static func createPrivateTab(engine choice: EngineChoice, hostView: NSView, initialURL: String) -> EngineTab {
        engine(choice).createPrivateTab(hostView: hostView, initialURL: initialURL)
    }

    /// CEF owns quitting -- see the type's doc comment.
    static func setWindowCloseHandler(_ handler: @escaping () -> Void) {
        CEFEngine.setWindowCloseHandler(handler)
    }

    static var isTerminating: Bool { CEFEngine.isTerminating }

    static func setVisualLookUpAvailable(_ available: Bool) {
        EngineChoice.allCases.forEach { engine($0).setVisualLookUpAvailable(available) }
    }

    static func setBackgroundTabPolicy(_ policy: BackgroundTabPolicy) {
        EngineChoice.allCases.forEach { engine($0).setBackgroundTabPolicy(policy) }
    }

    static func setDownloadDirectory(_ path: String) {
        EngineChoice.allCases.forEach { engine($0).setDownloadDirectory(path) }
    }

    static func updateContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings]) {
        EngineChoice.allCases.forEach { engine($0).updateContentBlocking(domains: domains, profileSettings: profileSettings) }
    }

    static func setThreatInterstitialBuilder(_ builder: @escaping (_ host: String, _ originalURL: String) -> String) {
        EngineChoice.allCases.forEach { engine($0).setThreatInterstitialBuilder(builder) }
    }

    static func updateThreatBlocking(domains: [String], profileSettings: [String: EngineProfileThreatSettings]) {
        EngineChoice.allCases.forEach { engine($0).updateThreatBlocking(domains: domains, profileSettings: profileSettings) }
    }

    /// The one extension system, where this OS has it.
    static var extensions: EngineExtensionManager? {
        EngineChoice.allCases.lazy.compactMap { engine($0).extensions }.first
    }
}
