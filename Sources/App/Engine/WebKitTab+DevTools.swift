import AppKit
import WebKit

/// EngineTab's developer-tools members for the WebKit engine: WebKit's own
/// Web Inspector, docked into the app's container through the private
/// `_WKInspector` SPI. All of the SPI handling is in WebKitInspector.swift;
/// this only connects it to the tab and its delegate.
extension WebKitTab {
    /// Runs once per web view, at creation. Turning developer extras on here
    /// rather than at first open is what gives every page WebKit's own
    /// "Inspect Element" context-menu item from the start.
    func installDevTools() {
        let session = WebKitInspectorSession.session(for: webView)
        session.onOpen = { [weak self] in self?.delegate?.engineTabDevToolsDidOpen() }
        session.onClose = { [weak self] in self?.delegate?.engineTabDevToolsDidClose() }
        session.onDockSideRequest = { [weak self] side in self?.delegate?.engineTabDevToolsDidRequestDockSide(side) }
        session.onOpenURLExternally = { [weak self] url in
            self?.delegate?.engineTabDidRequestNewTab(url: url.absoluteString, disposition: .foregroundTab)
        }
    }

    private var devToolsSession: WebKitInspectorSession { WebKitInspectorSession.session(for: webView) }

    func showDevTools(panel: DevToolsPanel, dockSide: DevToolsDockSide, in container: NSView?) {
        if devToolsSession.show(panel: panel, dockSide: dockSide, in: container) { return }
        showSafariInspectorHandOff()
    }

    var isDevToolsOpen: Bool { devToolsSession.isOpen }

    func startElementPicker() { devToolsSession.startElementPicker() }

    func inspectElement(at point: NSPoint) { devToolsSession.inspectElement(at: point) }

    // MARK: - WKUIDelegatePrivate

    /// WebKit opened a local inspector for this page -- from showDevTools,
    /// or from its own "Inspect Element" context-menu item.
    @objc(_webView:didAttachLocalInspector:)
    func _webView(_ webView: WKWebView, didAttachLocalInspector inspector: AnyObject) {
        devToolsSession.inspectorDidConnect()
    }

    @objc(_webView:willCloseLocalInspector:)
    func _webView(_ webView: WKWebView, willCloseLocalInspector inspector: AnyObject) {
        devToolsSession.inspectorWillClose()
    }
}
