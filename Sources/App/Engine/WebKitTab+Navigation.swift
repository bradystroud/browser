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

    /// The navigation that loads our own error/crash page. Its commit and
    /// finish are not a visit: the page is ours, not the site's.
    var errorPageNavigation: WKNavigation?

    /// The real URL behind the error page currently on screen, so reload()
    /// retries the site instead of re-rendering the error HTML.
    var failedURL: URL?

    /// When the last automatic reload after a content-process crash
    /// happened. A second crash soon after shows the crash page instead of
    /// looping.
    var lastCrashReload: Date?
}

extension WebKitTab: WKNavigationDelegate {
    // MARK: - Policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, Self.isExternalScheme(url) {
            decisionHandler(.cancel)
            openExternally(url, navigationAction: navigationAction)
            return
        }
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
        decisionHandler(WebKitDownloadPolicy.shouldDownload(navigationResponse) ? .download : .allow)
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
        if navigation !== navigationState.errorPageNavigation {
            navigationState.failedURL = nil
        }
        // CEF's OnLoadStart, which fires after commit but before the new
        // document's own scripts run. didCommit is the closest WebKit hook:
        // the response has started arriving and the old document is gone,
        // but nothing guarantees the page's inline scripts haven't run yet.
        // A script that truly must win that race belongs in a WKUserScript
        // at .atDocumentStart instead.
        delegate?.engineTabDidStartMainFrameLoad()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === navigationState.errorPageNavigation {
            navigationState.errorPageNavigation = nil
            return
        }
        reportFinishedNavigation()
    }

    /// The document committed and then failed part-way (a dropped
    /// connection mid-page). What arrived is on screen, so it still counts
    /// as a visit -- CEF's OnLoadEnd fires for a main frame that committed
    /// whether or not it completed. A cancel is different: it means a newer
    /// navigation replaced this one, and that one gets its own report.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === navigationState.errorPageNavigation {
            navigationState.errorPageNavigation = nil
            return
        }
        NSLog("Browser: WebKit load failed after commit for %@: %@", webView.url?.absoluteString ?? "(nil)", error.localizedDescription)
        guard !Self.isBenignNavigationError(error) else { return }
        reportFinishedNavigation()
    }

    /// The navigation never committed: DNS, offline, refused connection,
    /// TLS failure. Without this the tab keeps showing the previous page (or
    /// stays blank) with nothing explaining why.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === navigationState.errorPageNavigation {
            navigationState.errorPageNavigation = nil
            return
        }
        let failingURL = Self.failingURL(of: error) ?? webView.url
        NSLog("Browser: WebKit load failed for %@: %@ (%@ %d)", failingURL?.absoluteString ?? "(nil)",
              error.localizedDescription, (error as NSError).domain, (error as NSError).code)
        guard !Self.isBenignNavigationError(error), let failingURL else { return }
        let page = WebKitErrorPage.loadFailure(error: error as NSError, url: failingURL)
        showErrorPage(page, for: failingURL)
    }

    /// The renderer process died (a crash, or the OS reclaiming memory).
    /// Reload once automatically, the way Safari does; a second death soon
    /// after shows a page explaining it instead of crash-looping.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let url = webView.url
        NSLog("Browser: WebKit web content process terminated for %@", url?.absoluteString ?? "(nil)")
        let now = Date()
        if let last = navigationState.lastCrashReload, now.timeIntervalSince(last) < 30 {
            guard let url, url.scheme == "http" || url.scheme == "https" else { return }
            showErrorPage(WebKitErrorPage.processCrashed(url: url), for: url)
            return
        }
        navigationState.lastCrashReload = now
        webView.reload()
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

    // MARK: - Error pages

    /// Loaded with the failing URL as its base, so the omnibox, the tab and
    /// Try Again all keep pointing at the address the user asked for.
    private func showErrorPage(_ html: String, for url: URL) {
        navigationState.failedURL = url
        navigationState.errorPageNavigation = webView.loadHTMLString(html, baseURL: url)
    }

    /// Called from reload(): on an error page, retry the real address rather
    /// than re-rendering the error HTML. Returns false when there is
    /// nothing to retry and an ordinary reload should happen.
    func retryFailedNavigationIfShowingErrorPage() -> Bool {
        guard let failedURL = navigationState.failedURL, webView.url == failedURL else { return false }
        navigationState.failedURL = nil
        loadURL(failedURL.absoluteString)
        return true
    }

    /// Cancellations are routine (a newer navigation replaced this one, or
    /// the user pressed Stop). WebKit's "frame load interrupted" is its own
    /// cancel for a navigation turned into a download or cancelled by
    /// policy, and "plug-in handled load" means something else took it over.
    static func isBenignNavigationError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return true }
        if error.domain == "WebKitErrorDomain", error.code == 102 || error.code == 204 { return true }
        return false
    }

    private static func failingURL(of error: Error) -> URL? {
        let userInfo = (error as NSError).userInfo
        if let url = userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let string = userInfo[NSURLErrorFailingURLStringErrorKey] as? String { return URL(string: string) }
        return nil
    }

    // MARK: - External schemes

    /// Schemes the web view renders itself. Anything else (mailto:, tel:,
    /// zoommtg:, slack:, ...) belongs to another app. The app has no custom
    /// internal scheme of its own: the start page and the threat
    /// interstitial are data: URLs.
    private static let webSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript"]

    static func isExternalScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// A click on a link opens the other app straight away, as any browser
    /// does. A page redirecting itself there (Zoom's and Teams' join pages do
    /// exactly this) is asked about first, and only for the main frame, so a
    /// hidden ad iframe can't launch apps or spam prompts.
    private func openExternally(_ url: URL, navigationAction: WKNavigationAction) {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSLog("Browser: no application to open %@", url.scheme ?? "")
            return
        }
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted:
            NSWorkspace.shared.open(url)
        default:
            guard navigationAction.targetFrame?.isMainFrame != false else { return }
            let appName = FileManager.default.displayName(atPath: appURL.path)
            let alert = NSAlert()
            alert.messageText = "Open \u{201C}\(appName)\u{201D}?"
            let site = webView.url?.host ?? "This page"
            alert.informativeText = "\(site) wants to open a link in \(appName)."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            present(alert) { response in
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - HTTP authentication

    /// Basic/Digest only get a username/password prompt. Every other method
    /// -- above all server trust -- takes WebKit's default handling, which
    /// rejects an untrusted certificate outright.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        var info = space.receivesCredentialSecurely
            ? "The server requires a username and password."
            : "The server requires a username and password. Your password will be sent unencrypted."
        if let realm = space.realm, !realm.isEmpty {
            info += "\n\nThe server says: \(realm)"
        }
        if challenge.previousFailureCount > 0 {
            info = "The username or password was incorrect. " + info
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        usernameField.placeholderString = "Username"
        usernameField.stringValue = challenge.proposedCredential?.user ?? ""
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(usernameField)
        accessory.addSubview(passwordField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = usernameField.stringValue.isEmpty ? usernameField : passwordField
        usernameField.nextKeyView = passwordField
        passwordField.nextKeyView = usernameField

        present(alert) { response in
            guard response == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let credential = URLCredential(user: usernameField.stringValue, password: passwordField.stringValue, persistence: .forSession)
            completionHandler(.useCredential, credential)
        }
    }

    /// As a sheet on this tab's window when it has one; a background tab
    /// that isn't in a window falls back to an app-modal alert.
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
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

/// Self-contained HTML for load failures and renderer crashes. No network
/// resources and no script: the page runs with the failing site's origin as
/// its base, and must render when the network is exactly what's broken.
enum WebKitErrorPage {
    static func loadFailure(error: NSError, url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let (heading, explanation) = describe(error, host: host)
        return render(heading: heading, explanation: explanation, url: url,
                      detail: "\(error.localizedDescription) (\(error.domain) \(error.code))")
    }

    static func processCrashed(url: URL) -> String {
        render(heading: "This page crashed",
               explanation: "The page stopped working, twice in a row. It may be using too much memory or hitting a bug.",
               url: url, detail: nil)
    }

    private static func describe(_ error: NSError, host: String) -> (String, String) {
        guard error.domain == NSURLErrorDomain else {
            return ("Can\u{2019}t open this page", "Something went wrong while loading \(host).")
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return ("You\u{2019}re not connected to the internet", "Check your network connection, then try again.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ("Can\u{2019}t find the server", "\(host) couldn\u{2019}t be found. Check the address for typos.")
        case NSURLErrorCannotConnectToHost:
            return ("Can\u{2019}t connect to the server", "\(host) refused the connection or isn\u{2019}t responding.")
        case NSURLErrorTimedOut:
            return ("The server took too long to respond", "\(host) didn\u{2019}t answer in time.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return ("Can\u{2019}t establish a secure connection",
                    "The connection to \(host) isn\u{2019}t secure, so the page wasn\u{2019}t loaded. Someone may be impersonating the site, or its certificate is misconfigured.")
        case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
            return ("Can\u{2019}t open this address", "This browser can\u{2019}t open that kind of link.")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return ("Can\u{2019}t open this page", "\(host) can only be loaded over a secure connection.")
        default:
            return ("Can\u{2019}t open this page", "Something went wrong while loading \(host).")
        }
    }

    private static func render(heading: String, explanation: String, url: URL, detail: String?) -> String {
        let href = escape(url.absoluteString)
        let detailHTML = detail.map { "<p class=\"detail\">\(escape($0))</p>" } ?? ""
        // No <title>: an empty title makes the tab show the URL, and a real
        // one would overwrite the history entry's title for that URL.
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --bg: #f5f5f7; --fg: #1d1d1f; --muted: #6e6e73; --accent: #0071e3; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f5f5f7; --muted: #98989d; --accent: #0a84ff; } }
        html, body { margin: 0; height: 100%; background: var(--bg); color: var(--fg);
          font: 15px -apple-system, BlinkMacSystemFont, sans-serif; }
        main { max-width: 520px; margin: 0 auto; padding: 18vh 24px 24px; }
        h1 { font-size: 24px; font-weight: 600; margin: 0 0 12px; }
        p { line-height: 1.5; margin: 0 0 12px; }
        .url { color: var(--muted); word-break: break-all; }
        .detail { color: var(--muted); font-size: 13px; }
        a.button { display: inline-block; margin-top: 12px; padding: 8px 18px; border-radius: 8px;
          background: var(--accent); color: #fff; text-decoration: none; font-weight: 500; }
        </style></head>
        <body><main>
        <h1>\(escape(heading))</h1>
        <p>\(escape(explanation))</p>
        <p class="url">\(href)</p>
        \(detailHTML)
        <a class="button" href="\(href)">Try Again</a>
        </main></body></html>
        """
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
