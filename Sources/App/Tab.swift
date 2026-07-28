import AppKit

protocol TabDelegate: AnyObject {
    func tabDidChangeDisplayState(_ tab: Tab)

    /// A committed top-level (main-frame) navigation -- see
    /// EngineTabDelegate.engineTabDidCommitNavigation for exactly what this
    /// does and doesn't cover. This is the history-recording signal.
    func tab(_ tab: Tab, didCommitNavigationTo url: String)

    func tab(_ tab: Tab, didBeginDownload info: TabDownloadStart)
    func tab(_ tab: Tab, didUpdateDownload info: TabDownloadUpdate)

    /// Mirrors EngineTabDelegate.engineTabDidRequestPermission -- see that
    /// method's doc comment for the promptId/decision contract.
    func tab(_ tab: Tab, didRequestPermission kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void)

    /// Mirrors EngineTabDelegate.engineTabDidDismissPermissionRequest.
    func tab(_ tab: Tab, didDismissPermissionRequestWithId promptId: UInt64)
}

/// Mirrors EngineTabDelegate.engineTabDidBeginDownload -- a plain Swift value
/// so TabDelegate doesn't need to know about the engine protocol types.
struct TabDownloadStart {
    let downloadId: Int64
    let url: String
    let suggestedName: String
    let destinationPath: String
}

/// Mirrors EngineTabDelegate.engineTabDidUpdateDownload.
struct TabDownloadUpdate {
    let downloadId: Int64
    let receivedBytes: Int64
    let totalBytes: Int64
    let isComplete: Bool
    let isCancelled: Bool
    let isInterrupted: Bool
}

/// One browser tab: a persistent host NSView + EngineTab, plus the
/// navigation/display state the tab strip and omnibox render. The host view
/// is created once and kept alive for the tab's lifetime, including while
/// the tab is not the active one in its window -- switching tabs detaches/
/// reattaches this view from the window's content container rather than
/// destroying and recreating the underlying EngineTab (see AppDelegate/
/// BrowserWindowController), matching the plan's requirement that inactive
/// tabs keep their engine-side browser alive.
final class Tab: NSObject, EngineTabDelegate {
    let id = UUID()
    let profileName: String
    let hostView = NSView()

    /// True for a Private Browsing tab (browser-12m.1). `profileName` above
    /// is still set (to whatever throwaway profile the owning window uses
    /// cosmetically -- see WindowManager.openNewPrivateWindow) but is never
    /// used to look up or create a real engine-side profile context for this
    /// tab; see createBrowserIfNeeded(). BrowserWindowController reads this
    /// to suppress history/download/permission persistence and the "Private"
    /// label; WindowManager reads it to exclude the tab's window from session
    /// save/restore.
    let isPrivate: Bool

    private(set) var browser: EngineTab?
    private(set) var title: String

    /// The engine's real, current URL -- the internal start page's own
    /// (giant, base64-encoded) data: URL while showing it. `urlString`
    /// below is the public-facing value everything else in the app should
    /// read (e.g. the omnibox, ⌘⇧C); it reports "" instead while
    /// `isShowingStartPage`, which is what makes the omnibox show empty for
    /// the start page without BrowserWindowController's display code
    /// needing to know anything about it (browser-5kq.3).
    private var engineURLString: String
    var urlString: String { isShowingStartPage ? "" : engineURLString }

    /// True while this tab is showing the internal start page (see
    /// StartPageRenderer) rather than something the user actually
    /// navigated to. Cleared the moment engineTabDidChangeURL reports any
    /// other URL (a real navigation, e.g. clicking a Favorites/Frequently
    /// Visited tile).
    private(set) var isShowingStartPage: Bool

    private(set) var faviconURL: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// True until this tab's first load finishes, then consumed. CEF's
    /// CefFocusHandler::OnSetFocus defaults to allowing the browser's own
    /// focus requests (and BRWClientHandler doesn't override it), so the
    /// freshly created native view reliably grabs first responder for
    /// itself once its initial paint completes -- shortly *after*
    /// BrowserWindowController.addTab's own makeFirstResponder(omniboxField)
    /// call on the very same tick, winning that race every time (confirmed
    /// by reproducing a fresh tab's omnibox losing focus by the time a
    /// keypress arrives ~0.5s later). Re-asserting the omnibox once loading
    /// settles, exactly once per tab, fixes it without permanently blocking
    /// the browser from ever taking focus (e.g. when the user clicks into
    /// the page deliberately).
    var needsInitialOmniboxFocus = true

    /// Nil until FaviconLoader resolves one; the tab strip falls back to a
    /// generic glyph until then (or forever, if the site has none/it fails
    /// to load) -- see TabButtonView.
    private(set) var faviconImage: NSImage?
    private var faviconFetchKey: String?

    /// Pinned tabs sort to a contiguous prefix at the front of the owning
    /// window's `tabs` array (see BrowserWindowController.pinTab/unpinTab)
    /// and render compact -- Safari-style: small fixed width, favicon-only,
    /// no close button, and immune to ⌘W. Persisted via
    /// SessionSnapshot.Tab.isPinned; pure UI/session state, no engine-side
    /// counterpart.
    var isPinned = false

    /// Which TabGroup (if any) this tab belongs to -- see
    /// BrowserWindowController.tabGroups/moveTab(at:toGroup:). Mutually
    /// exclusive with isPinned: moving into a group always unpins first,
    /// and pinning always clears this (see the ordering invariant on
    /// BrowserWindowController.tabs: [pinned][group sections][loose]).
    /// Persisted via SessionSnapshot.Tab.groupId; pure UI/session state.
    var groupId: UUID?

    /// The current page's declared brand color, from `<meta name=
    /// "theme-color">` -- applied as a low-alpha tint to this tab's button
    /// (while active) and its window's toolbar; see BrowserWindowController.
    /// refreshToolbar(for:)/TabButtonView.draw(_:). nil whenever the current
    /// page has none (including briefly after each new navigation, until
    /// refreshThemeColor's async check resolves -- see its doc comment for
    /// why that's the right default rather than keeping the previous page's
    /// color). Not persisted -- purely a live-session visual, re-derived
    /// fresh on every navigation and on session restore's first real load.
    private(set) var themeColorHex: String?

    /// True while this tab's audio output is muted (browser-rhi.4) -- a
    /// direct wrapper over CefBrowserHost::SetAudioMuted/IsAudioMuted (a
    /// real one-call mute, confirmed present in this project's pinned CEF
    /// 150.0.14 headers; no JS workaround needed for muting itself). Not
    /// persisted across app restarts -- like Chrome/Safari, a fresh launch
    /// always starts every tab unmuted, matching CEF's own default.
    private(set) var isMuted = false

    /// True while this tab's page is believed to be actively playing audio
    /// (browser-rhi.4) -- CEF exposes no native "audible" callback (unlike
    /// SetAudioMuted/IsAudioMuted above), so this is derived from JS
    /// (AudioStateScript.swift, injected on document-start) reporting via a
    /// marker attribute polled through getPageSource(completion:) -- see
    /// TabAudioCoordinator, the same pattern ReaderModeController already
    /// established for its own "is this page readerable" signal. Cleared on
    /// every navigation (see engineTabDidStartMainFrameLoad below) since a
    /// brand-new document has no media elements yet until proven otherwise.
    private(set) var isAudible = false

    /// Toggles isMuted and immediately applies it to the engine -- the only
    /// place SetAudioMuted is ever called, so isMuted can never drift from
    /// what the engine actually has (no separate "read it back to confirm"
    /// step needed).
    func toggleMuted() {
        isMuted.toggle()
        browser?.setAudioMuted(isMuted)
        delegate?.tabDidChangeDisplayState(self)
    }

    /// Called by TabAudioCoordinator's poll once per tick with whatever the
    /// injected script's marker attribute currently says -- a no-op unless
    /// the value actually changed, so the tab strip isn't asked to redraw
    /// every tick for a steady-state tab.
    func updateAudibleState(_ audible: Bool) {
        guard audible != isAudible else { return }
        isAudible = audible
        delegate?.tabDidChangeDisplayState(self)
    }

    /// Bumped on every navigation so a stale getPageSource(completion:)
    /// result from a page that's since been navigated away from can't
    /// clobber a newer page's (possibly nil) theme color -- same guard
    /// shape as faviconFetchKey above.
    private var themeColorFetchGeneration = 0

    weak var delegate: TabDelegate?

    /// BrowserWindowController's existing sentinel for "no specific page
    /// requested" (⌘T new tabs load this literal string) -- also what a
    /// restored start-page tab's persisted (empty, since urlString reports
    /// "" while showing it) URL resolves to on relaunch, so both count as
    /// "show the start page" below. Tab intercepts either here rather than
    /// letting the engine actually try to navigate to them.
    private static let blankPageSentinel = "about:blank"

    init(profileName: String, initialURL: String, isPrivate: Bool = false) {
        self.profileName = profileName
        self.isPrivate = isPrivate
        let resolved = Self.resolveInitialLoad(initialURL, profileName: profileName, isPrivate: isPrivate)
        self.isShowingStartPage = resolved.isStartPage
        self.engineURLString = resolved.url
        self.title = resolved.isStartPage ? "New Tab" : initialURL
        super.init()
        hostView.wantsLayer = true
    }

    private static func resolveInitialLoad(_ requestedURL: String, profileName: String, isPrivate: Bool) -> (url: String, isStartPage: Bool) {
        guard requestedURL == blankPageSentinel || requestedURL.isEmpty else {
            return (requestedURL, false)
        }
        return (StartPageRenderer.dataURL(profileName: profileName, isPrivate: isPrivate), true)
    }

    /// Must be called only once `hostView` is attached to a window with a
    /// real frame (CEF's SetAsChild needs real bounds at creation time).
    func createBrowserIfNeeded() {
        guard browser == nil else { return }
        // A private tab never goes through ActiveEngine.createTab(profileName:...)
        // -- that path always resolves to a persisted-cache_path context (see
        // BRWGetOrCreateProfileContext), even for a made-up profile name.
        // createPrivateTab is the only path that gets CEF's actual empty-
        // cache_path incognito context (browser-12m.1).
        let browser = isPrivate
            ? ActiveEngine.createPrivateTab(hostView: hostView, initialURL: engineURLString)
            : ActiveEngine.createTab(profileName: profileName, hostView: hostView, initialURL: engineURLString)
        browser.delegate = self
        self.browser = browser
    }

    func load(url: String) {
        let resolved = Self.resolveInitialLoad(url, profileName: profileName, isPrivate: isPrivate)
        isShowingStartPage = resolved.isStartPage
        engineURLString = resolved.url
        if browser == nil {
            createBrowserIfNeeded()
        } else {
            browser?.loadURL(resolved.url)
        }
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }

    func showDevTools() { browser?.showDevTools() }
    func closeDevTools() { browser?.closeDevTools() }

    /// Responsive Design Mode (browser-6hi.2) -- see EngineTab's own doc
    /// comment for why this doesn't need DevTools' own UI open at all.
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        browser?.setResponsiveDesignMode(width: width, height: height, deviceScaleFactor: deviceScaleFactor, mobile: mobile)
    }

    func clearResponsiveDesignMode() {
        browser?.clearResponsiveDesignMode()
    }

    func print() { browser?.print() }

    /// Exports the current page to a PDF at `path` -- see
    /// EngineTab.printToPDF(path:completion:) for the default print settings
    /// this leaves untouched. No-ops (reporting failure) if this tab has no
    /// engine-side browser yet, same guard every other browser?.-prefixed
    /// call above already relies on implicitly.
    func exportAsPDF(to path: String, completion: @escaping (Bool, String) -> Void) {
        guard let browser else {
            completion(false, path)
            return
        }
        browser.printToPDF(path: path, completion: completion)
    }

    func find(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        browser?.find(searchText, forward: forward, matchCase: matchCase, findNext: findNext)
    }

    func stopFinding(clearSelection: Bool) {
        browser?.stopFinding(clearSelection: clearSelection)
    }

    func executeJavaScript(_ code: String) {
        browser?.executeJavaScript(code)
    }

    func getPageSource(completion: @escaping (String?) -> Void) {
        guard let browser else {
            completion(nil)
            return
        }
        browser.getPageSource(completion: completion)
    }

    /// Answers a page message previously delivered via onPageMessage below --
    /// see EngineTab.respondToPageMessage for the exact contract (in
    /// particular, `requestId` is global across every tab, so this can be
    /// called on any live Tab, not just the one that received the message).
    func respondToPageMessage(requestId: Int64, success: Bool, response: String) {
        browser?.respondToPageMessage(requestId: requestId, success: success, response: response)
    }

    /// Set by FindBarController while it's attached to this tab and the find
    /// bar is showing, to receive live match-count updates -- deliberately a
    /// plain closure property rather than a new TabDelegate method: TabDelegate
    /// is implemented by BrowserWindowController (hot with concurrent Tab
    /// Groups work at the time this was written), and find results are
    /// FindBarController's concern alone, not something the window controller
    /// itself needs to know about.
    var onFindResult: ((_ matchCount: Int, _ activeMatchOrdinal: Int, _ isFinalUpdate: Bool) -> Void)?

    func engineTabDidUpdateFindResult(matchCount: Int, activeMatchOrdinal: Int, isFinalUpdate: Bool) {
        onFindResult?(matchCount, activeMatchOrdinal, isFinalUpdate)
    }

    /// Set by whichever feature controller wants this tab's raw page
    /// messages (browser-ojh.1's password-manager form-detection script is
    /// the first user) -- a plain closure property for the same reason as
    /// onFindResult just above: TabDelegate is implemented by the hot
    /// BrowserWindowController, and this generic channel's messages are a
    /// feature controller's concern, not the window controller's. `request`
    /// is an opaque string the page passed to `window.cefQuery` -- callers
    /// parse their own payload shape out of it (see BRWBrowser.h's
    /// -browserDidReceivePageMessage:requestId: for the full contract,
    /// including that not calling respondToPageMessage(requestId:...)
    /// exactly once leaves the page's promise pending forever).
    var onPageMessage: ((_ request: String, _ requestId: Int64) -> Void)?

    func engineTabDidReceivePageMessage(_ request: String, requestId: Int64) {
        onPageMessage?(request, requestId)
    }

    /// Seeds a restored tab's display title immediately at launch, before
    /// its page has even started (re)loading, so the tab strip shows a real
    /// title right away instead of the raw URL -- the real page's own title
    /// arrives later via engineTabDidChangeTitle and naturally overwrites
    /// this. See WindowManager.restoreSession.
    func seedRestoredTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    func close() {
        browser?.close()
        browser = nil
    }

    // MARK: - EngineTabDelegate

    func engineTabDidChangeTitle(_ title: String) {
        self.title = title.isEmpty ? urlString : title
        delegate?.tabDidChangeDisplayState(self)
    }

    func engineTabDidChangeURL(_ url: String) {
        // The gear button's plain `<a href="#browser-settings">` link is a
        // same-document fragment click -- no real navigation/request, just
        // an address-bar-style report of the new (fragment-suffixed) URL --
        // so it's caught here rather than needing a JS-to-Swift bridge
        // message channel (none exists yet) or CEF request interception.
        // Returns without touching engineURLString/isShowingStartPage: this
        // never happened as far as the rest of the tab's state is
        // concerned.
        if isShowingStartPage, url == engineURLString + StartPageRenderer.settingsFragment {
            SettingsWindowController.shared.showStartPageTab()
            return
        }
        if url != engineURLString {
            isShowingStartPage = false
        }
        engineURLString = url
        delegate?.tabDidChangeDisplayState(self)
    }

    func engineTabDidChangeFaviconURL(_ faviconURL: String?) {
        self.faviconURL = faviconURL
        maybeLoadFavicon()
        delegate?.tabDidChangeDisplayState(self)
    }

    func engineTabDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        delegate?.tabDidChangeDisplayState(self)
    }

    /// Document-start hook (browser-ojh.1) -- injects the password-form
    /// watcher on every top-level navigation, unconditionally, regardless of
    /// whether this tab is currently visible/active. Deliberately not gated
    /// behind any per-window controller: a background tab's form can still
    /// be submitted (e.g. after a redirect finishes while another tab has
    /// focus), and missing that would silently drop a save-password
    /// opportunity. The script itself is a no-op past its first run per
    /// document (see PasswordDetectionScript's own guard) and reports
    /// through the generic page-message channel (onPageMessage below),
    /// which whichever PasswordManagerController is currently watching this
    /// tab picks up -- see that class's own doc comment for why *that* part,
    /// unlike injection, does need to be window-scoped.
    func engineTabDidStartMainFrameLoad() {
        guard !isShowingStartPage else { return }
        executeJavaScript(PasswordDetectionScript.source)
        // Separate script, separate cefQuery message types (browser-ojh.2)
        // -- injected alongside, not merged into, PasswordDetectionScript,
        // so the two features' detection logic stay independently
        // readable/testable even though they share the same delivery
        // mechanism.
        executeJavaScript(PaymentAddressDetectionScript.source)
        // Separate script again, same reasoning (browser-rhi.4) -- reports
        // through TabAudioCoordinator's poll (getPageSource + marker
        // attribute), not the cefQuery channel the two scripts above use,
        // since this signal is coarse/polling-tolerant and doesn't need a
        // dedicated channel of its own -- see TabAudioCoordinator's doc
        // comment for why.
        executeJavaScript(AudioStateScript.source)
        // Separate script again (browser-7jz.3) -- overrides
        // window.Notification; reports through the same cefQuery channel
        // as the two scripts above (see NotificationOverrideScript's own
        // doc comment for why this is safe now that PageMessageDispatcher
        // arbitrates registrations by message type, unlike earlier this
        // session).
        executeJavaScript(NotificationOverrideScript.source)
    }

    func engineTabDidCommitNavigation(_ url: String) {
        // The start page's own data: URL "navigation" isn't a real visit --
        // skip favicon/theme-color derivation and (most importantly) the
        // history-recording delegate call for it.
        guard !isShowingStartPage else { return }
        maybeLoadFavicon()
        refreshThemeColor()
        // A brand-new document has no media elements yet until the poll
        // (or a real play event) proves otherwise -- same "clear
        // immediately on navigate-away" reasoning as themeColorHex's own
        // reset in refreshThemeColor(), so a background tab's stale
        // "playing" indicator can't survive a navigation to a silent page.
        updateAudibleState(false)
        delegate?.tab(self, didCommitNavigationTo: url)
    }

    /// Re-derives themeColorHex for the page that just committed (browser-
    /// rhi.5). Cleared immediately, not just on a nil/failed result: "cleared
    /// on navigate-away if the new page lacks the tag" means the default for
    /// a brand-new page is untinted until proven otherwise, not "keep
    /// showing the previous page's color while this checks."
    ///
    /// Reads the tag via getPageSource(completion:) (CefFrame::GetSource --
    /// a real async CEF API, see EngineTab's doc comment) rather than
    /// injecting JS and reading a result back through some ad hoc side
    /// channel: executeJavaScript(_:) is genuinely fire-and-forget (no
    /// result path exists in CEF's API at all -- see BRWBrowser.h), and
    /// GetSource already reflects the live DOM (Reader mode relies on this
    /// same fact to read back a marker attribute *injected JS itself* sets),
    /// so it's the correct, already-proven tool for this too.
    private func refreshThemeColor() {
        themeColorFetchGeneration += 1
        let generation = themeColorFetchGeneration
        if themeColorHex != nil {
            themeColorHex = nil
            delegate?.tabDidChangeDisplayState(self)
        }
        browser?.getPageSource { [weak self] source in
            guard let self, self.themeColorFetchGeneration == generation, let source,
                  let hex = Self.extractThemeColorHex(fromHTML: source), NSColor(hex: hex) != nil else { return }
            self.themeColorHex = hex
            self.delegate?.tabDidChangeDisplayState(self)
        }
    }

    /// Matches `<meta name="theme-color" content="...">`, tolerating either
    /// attribute order (name-then-content is by far the more common
    /// convention in the wild, but content-then-name is equally valid HTML).
    /// Only a hex color value is recognized (see NSColor(hex:) -- "#RGB" and
    /// "#RRGGBB"); a named CSS color (e.g. "tomato") or an rgb(...)/hsl(...)
    /// function value is treated as absent rather than parsed -- a
    /// deliberate v1 scope cut, see docs/ai-tasks/browser-rhi.5-notes.md.
    private static let themeColorNameFirstRegex = try? NSRegularExpression(
        pattern: #"<meta[^>]+name=["']theme-color["'][^>]*content=["']([^"']+)["']"#, options: .caseInsensitive)
    private static let themeColorContentFirstRegex = try? NSRegularExpression(
        pattern: #"<meta[^>]+content=["']([^"']+)["'][^>]*name=["']theme-color["']"#, options: .caseInsensitive)

    private static func extractThemeColorHex(fromHTML html: String) -> String? {
        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        for regex in [themeColorNameFirstRegex, themeColorContentFirstRegex] {
            guard let match = regex?.firstMatch(in: html, range: range), match.numberOfRanges > 1 else { continue }
            return nsHTML.substring(with: match.range(at: 1))
        }
        return nil
    }

    /// FaviconLoader.shared.loadFavicon(...), fired on committed navigation
    /// and again if a more accurate favicon URL hint arrives afterward (see
    /// FaviconLoader's doc comment on why the hint is preferred over
    /// guessing /favicon.ico). faviconFetchKey -- host + whatever hint we
    /// have right now -- avoids redundant fetches for the same combination
    /// while still re-fetching if a better hint shows up later for the same
    /// host.
    private func maybeLoadFavicon() {
        guard let host = URL(string: urlString)?.host else { return }
        let key = "\(host)|\(faviconURL ?? "")"
        guard key != faviconFetchKey else { return }
        faviconFetchKey = key
        FaviconLoader.shared.loadFavicon(host: host, hintURL: faviconURL, profileName: profileName) { [weak self] image in
            guard let self, self.faviconFetchKey == key else { return }
            self.faviconImage = image
            self.delegate?.tabDidChangeDisplayState(self)
        }
    }

    func engineTabDidBeginDownload(id downloadId: Int64, url: String, suggestedName: String, destinationPath: String) {
        delegate?.tab(self, didBeginDownload: TabDownloadStart(
            downloadId: downloadId, url: url, suggestedName: suggestedName, destinationPath: destinationPath))
    }

    func engineTabDidUpdateDownload(id downloadId: Int64, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCancelled: Bool, isInterrupted: Bool) {
        delegate?.tab(self, didUpdateDownload: TabDownloadUpdate(
            downloadId: downloadId, receivedBytes: receivedBytes, totalBytes: totalBytes,
            isComplete: isComplete, isCancelled: isCancelled, isInterrupted: isInterrupted))
    }

    func engineTabDidRequestPermission(_ kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        delegate?.tab(self, didRequestPermission: kinds, promptId: promptId, requestingOrigin: requestingOrigin, decision: decision)
    }

    func engineTabDidDismissPermissionRequest(_ promptId: UInt64) {
        delegate?.tab(self, didDismissPermissionRequestWithId: promptId)
    }
}
