import AppKit
import WebKit

/// Per-tab bookkeeping the navigation delegate needs across callbacks.
/// A class held by WebKitTab (extensions can't add stored properties), so
/// this file owns every field it reads and writes.
final class WebKitNavigationState {
    /// Bumped at every provisional start, so an async step that began for
    /// one navigation (the favicon read in didFinish) can tell it has been
    /// superseded by the next one.
    var generation = 0
}

extension WebKitTab: WKNavigationDelegate {
    // MARK: - Policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // target="_blank"/window.open() -- see
        // webView(_:createWebViewWith:for:windowFeatures:) for the matching
        // new-tab signal. The threat-warning check only applies to top-level
        // main-frame navigations, matching
        // BRWClientHandler::OnBeforeResourceLoad's own scope for this feature.
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

    // MARK: - Navigation lifecycle
    //
    // CEF's order, which this reproduces: OnBeforeBrowse (will-start) ->
    // OnLoadingProgressChange (repeatedly) -> OnLoadStart (document start)
    // -> OnFaviconURLChange -> OnLoadEnd (commit, i.e. "visited").

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationState.generation += 1
        guard let url = webView.url?.absoluteString else { return }
        delegate?.engineTabWillStartMainFrameNavigation(url)
    }

    /// CEF's OnBeforeBrowse runs again for every redirect hop, so the
    /// optimistic omnibox text follows the redirect there too.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        delegate?.engineTabWillStartMainFrameNavigation(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // CEF's OnLoadStart, which fires after commit but before the new
        // document's own scripts run. didCommit is the closest WebKit hook:
        // the response has started arriving and the old document is gone,
        // but nothing guarantees the page's inline scripts haven't run yet.
        // A script that truly must win that race belongs in a WKUserScript
        // at .atDocumentStart instead.
        delegate?.engineTabDidStartMainFrameLoad()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reportFinishedNavigation()
    }

    /// Reads the page's declared icons, reports the chosen one, then reports
    /// the visit -- the same order CEF delivers OnFaviconURLChange and
    /// OnLoadEnd in, which matters: FaviconLoader caches by host, so a hint
    /// that arrives after the first fetch is ignored.
    private func reportFinishedNavigation() {
        let generation = navigationState.generation
        webView.evaluateJavaScript(Self.faviconCandidatesScript) { [weak self] result, _ in
            guard let self, self.navigationState.generation == generation,
                  let url = self.webView.url?.absoluteString else { return }
            let candidates = (result as? [[String: Any]] ?? []).compactMap(FaviconCandidate.init)
            self.delegate?.engineTabDidChangeFaviconURL(FaviconCandidate.best(of: candidates))
            self.delegate?.engineTabDidCommitNavigation(url)
        }
    }

    // MARK: - Favicons

    /// Every declared icon link in document order. `link.href` is already
    /// resolved against the document's base URL.
    static let faviconCandidatesScript = """
    (() => Array.from(document.querySelectorAll('link[rel][href]')).map(l => ({
      rel: (l.getAttribute('rel') || '').toLowerCase(),
      href: l.href,
      type: (l.getAttribute('type') || '').toLowerCase()
    })))()
    """
}

/// One `<link>` the favicon script found.
struct FaviconCandidate {
    let rels: Set<String>
    let href: String
    let type: String

    init?(_ dictionary: [String: Any]) {
        guard let rel = dictionary["rel"] as? String, let href = dictionary["href"] as? String, !href.isEmpty else { return nil }
        rels = Set(rel.split(whereSeparator: \.isWhitespace).map(String.init))
        self.href = href
        type = dictionary["type"] as? String ?? ""
    }

    private var isIcon: Bool { rels.contains("icon") }
    private var isTouchIcon: Bool { rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") }
    private var isSVG: Bool { type == "image/svg+xml" || href.lowercased().hasSuffix(".svg") }

    /// CEF hands over Chromium's favicon list and the app takes its first
    /// entry, which is the first `rel~=icon` in document order. SVG is
    /// passed over when anything else is declared, because FaviconLoader
    /// decodes through NSImage and a hint it can't decode means no icon at
    /// all rather than the /favicon.ico fallback. Touch icons are a last
    /// resort. nil lets FaviconLoader guess /favicon.ico.
    static func best(of candidates: [FaviconCandidate]) -> String? {
        let icons = candidates.filter(\.isIcon)
        if let icon = icons.first(where: { !$0.isSVG }) ?? icons.first { return icon.href }
        return candidates.first(where: \.isTouchIcon)?.href
    }
}
