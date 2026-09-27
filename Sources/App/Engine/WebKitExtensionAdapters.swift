import AppKit
import WebKit

// The app's tabs and windows, as WebKit's extension system is told about
// them. WKWebExtensionTab/Window are Objective-C protocols and the app's own
// ExtensionHostTab/Window are not, so each gets a small adapter; one adapter
// per host object for as long as it is open, so WebKit sees the same tab
// every time it asks.

@available(macOS 15.4, *)
final class WebKitExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var hostTab: ExtensionHostTab?
    private weak var profile: WebKitExtensionProfile?

    init(hostTab: ExtensionHostTab, profile: WebKitExtensionProfile) {
        self.hostTab = hostTab
        self.profile = profile
    }

    private var webView: WKWebView? { (hostTab?.extensionEngineTab as? WebKitTab)?.webView }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let window = hostTab?.extensionWindow else { return nil }
        return profile?.windowAdapter(for: window)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let hostTab, let tabs = hostTab.extensionWindow?.extensionTabs else { return NSNotFound }
        return tabs.firstIndex { $0 === hostTab } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { hostTab?.extensionTitle }
    func url(for context: WKWebExtensionContext) -> URL? { hostTab?.extensionURL }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(hostTab?.extensionIsLoading ?? false) }
    func isPinned(for context: WKWebExtensionContext) -> Bool { hostTab?.extensionIsPinned ?? false }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let hostTab else { return false }
        return hostTab.extensionWindow?.extensionActiveTab === hostTab
    }

    func size(for context: WKWebExtensionContext) -> CGSize { webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }

    /// A click in a page counts as the user invoking the extension there,
    /// which is what `activeTab` means in Chrome.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        hostTab?.extensionSetPinned(pinned)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        hostTab?.extensionLoad(url)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
    }

    func goBack(for context: WKWebExtensionContext) async throws { webView?.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { webView?.goForward() }
    func activate(for context: WKWebExtensionContext) async throws { hostTab?.extensionActivate() }
    func close(for context: WKWebExtensionContext) async throws { hostTab?.extensionClose() }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let webView else { return nil }
        return try await webView.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
final class WebKitExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var hostWindow: ExtensionHostWindow?
    private weak var profile: WebKitExtensionProfile?

    init(hostWindow: ExtensionHostWindow, profile: WebKitExtensionProfile) {
        self.hostWindow = hostWindow
        self.profile = profile
    }

    private var nsWindow: NSWindow? { hostWindow?.extensionNSWindow }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let profile, let hostWindow else { return [] }
        return hostWindow.extensionTabs.map { profile.tabAdapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let profile, let tab = hostWindow?.extensionActiveTab else { return nil }
        return profile.tabAdapter(for: tab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    /// Extensions never see a private window at all, so every window they
    /// are shown is a normal one.
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext) async throws {
        guard let window = nsWindow else { return }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .fullscreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .maximized: if !window.isZoomed { window.zoom(nil) }
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        @unknown default: break
        }
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        nsWindow?.setFrame(frame, display: true)
    }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate(ignoringOtherApps: true)
        nsWindow?.makeKeyAndOrderFront(nil)
    }

    func close(for context: WKWebExtensionContext) async throws {
        hostWindow?.extensionClose()
    }
}
