import AppKit
import WebKit

extension WebKitTab: WKUIDelegate {
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
        delegate?.engineTabDidRequestPermission(kinds, promptId: promptId, requestingOrigin: Self.permissionOrigin(origin), decision: { allow in
            decisionHandler(allow ? .grant : .deny)
        })
        // No engineTabDidDismissPermissionRequest equivalent wired up:
        // WKUIDelegate gives no separate "the request went away" callback
        // the way CEF's own permission handler does -- this decisionHandler
        // either gets called or (if the page/frame goes away first) is
        // presumably released by WebKit uninvoked. Not verified without a
        // live test.
    }

    /// The same prompt path as media capture above. WebKit only has this hook
    /// from macOS 27; on older systems WebKit never asks and the page's
    /// geolocation request is denied.
    @available(macOS 27.0, *)
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let promptId = UInt64.random(in: .min ... .max)
        delegate?.engineTabDidRequestPermission(.geolocation, promptId: promptId, requestingOrigin: Self.permissionOrigin(origin), decision: { allow in
            decisionHandler(allow ? .grant : .deny)
        })
    }

    // Notifications have no WKUIDelegate hook in any OS version. The CEF
    // side's notification support (Notifications/NotificationOverrideScript.swift)
    // is a JS-level window.Notification polyfill over the generic
    // page-message channel, so it would port onto this engine's
    // WKScriptMessageHandlerWithReply channel unchanged -- it just hasn't been.

    /// The page called window.close(). WebKit only calls this when it would
    /// let the page close itself (a DOM-opened window, or one with a single
    /// back/forward entry).
    ///
    /// Deliberately not acted on yet. EngineTabDelegate has no "close this
    /// tab" callback, and the CEF engine's equivalent (DoClose left at its
    /// default) closes the whole host NSWindow -- which here would take every
    /// other tab in the window with it, because window.open() becomes a tab
    /// on this engine, not a window.
    func webViewDidClose(_ webView: WKWebView) {
        NSLog("Browser: WebKit page requested window.close(); not honoured (no per-tab close path on EngineTabDelegate yet)")
    }

    // MARK: - JavaScript dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeDialog(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        presentPageSheet(alert.window, in: webView, fallback: completionHandler, start: { window, done in
            alert.beginSheetModal(for: window, completionHandler: done)
        }, finish: { _ in completionHandler() })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeDialog(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        presentPageSheet(alert.window, in: webView, fallback: { completionHandler(false) }, start: { window, done in
            alert.beginSheetModal(for: window, completionHandler: done)
        }, finish: { response in completionHandler(response == .alertFirstButtonReturn) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = makeDialog(message: prompt, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        presentPageSheet(alert.window, in: webView, fallback: { completionHandler(nil) }, start: { window, done in
            alert.beginSheetModal(for: window, completionHandler: done)
            alert.window.makeFirstResponder(field)
        }, finish: { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        })
    }

    // MARK: - File upload

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        presentPageSheet(panel, in: webView, fallback: { completionHandler(nil) }, start: { window, done in
            panel.beginSheetModal(for: window, completionHandler: done)
        }, finish: { response in
            completionHandler(response == .OK ? panel.urls : nil)
        })
    }

    // MARK: - Helpers

    /// The origin string handed to the app's permission prompt and store.
    /// Media capture and geolocation must agree on it, or a remembered
    /// decision for one origin would be keyed two different ways.
    static func permissionOrigin(_ origin: WKSecurityOrigin) -> String {
        origin.protocol + "://" + origin.host
    }

    /// Chrome's dialog shape: "<host> says" as the title, the page's own text
    /// below it. A page with no host (file:, data:, about:blank) gets
    /// "This page says" rather than an empty or misleading origin.
    private func makeDialog(message: String, frame: WKFrameInfo) -> NSAlert {
        let origin = frame.securityOrigin
        var host = origin.host
        if !host.isEmpty, origin.port != 0 {
            host += ":\(origin.port)"
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        // A page can pass megabytes of text; NSAlert grows to fit it and ends
        // up taller than the screen, with its buttons unreachable.
        alert.informativeText = message.count > 5_000 ? String(message.prefix(5_000)) + "…" : message
        return alert
    }

    /// Presents a page-initiated sheet on this tab's window, or answers the
    /// page with `fallback` straight away when a sheet can't be shown: the
    /// tab is in the background (its web view is not in a window), this tab
    /// already has one up, or the window already has some other sheet
    /// attached -- AppKit would queue ours behind it, and a queued sheet
    /// outliving its tab is exactly what the guard exists to prevent.
    private func presentPageSheet(_ sheet: NSWindow, in webView: WKWebView,
                                  fallback: @escaping () -> Void,
                                  start: @escaping (NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void,
                                  finish: @escaping (NSApplication.ModalResponse) -> Void) {
        let sheetGuard = WebKitPageSheetGuard.guardFor(webView)
        guard let window = webView.window, !sheetGuard.isPresenting, window.attachedSheet == nil else {
            fallback()
            return
        }
        sheetGuard.present(sheet: sheet, on: window, start: { done in start(window, done) }, finish: finish)
    }
}
