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
}
