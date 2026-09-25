import AppKit
import WebKit

extension WebKitTab: WKNavigationDelegate {
    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // target="_blank"/window.open() -- see
        // webView(_:createWebViewWith:for:windowFeatures:) below for the
        // matching new-tab signal. Threat-warning check (browser-12m.6) only
        // applies to top-level main-frame navigations, matching
        // BRWClientHandler::OnBeforeResourceLoad's own scope for this
        // feature.
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, let host = url.host,
           WebKitEngine.shouldWarn(host: host, profileName: profileName),
           let dataURLString = WebKitEngine.interstitialDataURL(host: host, originalURL: url.absoluteString),
           let dataURL = URL(string: dataURLString) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: dataURL))
            return
        }
        // Cmd/Cmd+Shift/Shift/middle-click on an ordinary <a href> -- the
        // WebKit counterpart of BRWClientHandler::OnOpenURLFromTab. WebKit
        // (unlike Blink) doesn't resolve these into a disposition itself, but
        // WKNavigationAction does carry the originating event's own modifiers
        // and button, so this stays race-free (no live keyboard-state query)
        // and still respects a page's own preventDefault(), which suppresses
        // the navigation before this is ever consulted.
        if let disposition = Self.clickDisposition(for: navigationAction),
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            delegate?.engineTabDidRequestNewTab(url: url.absoluteString, disposition: disposition)
            return
        }
        decisionHandler(.allow)
    }

    /// The standard macOS link-click modifier overrides, or nil for an
    /// ordinary click that should just navigate in place.
    static func clickDisposition(for navigationAction: WKNavigationAction) -> EngineWindowOpenDisposition? {
        guard navigationAction.navigationType == .linkActivated else { return nil }
        // AppKit button numbers: 0 left, 1 right, 2 middle; -1 when the
        // navigation wasn't caused by a mouse event at all.
        if navigationAction.buttonNumber == 2 { return .backgroundTab }
        let modifiers = navigationAction.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) { return modifiers.contains(.shift) ? .foregroundTab : .backgroundTab }
        if modifiers.contains(.shift) { return .newWindow }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        delegate?.engineTabDidCommitNavigation(url)
        // Approximation, not CEF's exact guarantee: BRWBrowser's
        // -browserDidStartMainFrameLoad fires after commit but before the
        // new document's own scripts run (see BrowserEngine.swift's own doc
        // comment on the exact CEF contract). WKNavigationDelegate has no
        // equivalent hook -- didCommitNavigation fires once the response
        // begins arriving, close enough for this signal's actual use
        // (triggering a same-timing executeJavaScript(_:) injection) but not
        // a verified guarantee. The idiomatic WebKit way to guarantee
        // before-page-scripts injection is a persistent WKUserScript with
        // injectionTime .atDocumentStart added once to the
        // WKUserContentController -- a real production port of the
        // password-manager/autofill/notification-override scripts onto this
        // engine should very likely use that instead of reacting to this
        // signal with an imperative executeJavaScript(_:) call every time.
        delegate?.engineTabDidStartMainFrameLoad()
    }
}
