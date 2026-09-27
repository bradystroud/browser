import AppKit

protocol TabDelegate: AnyObject {
    func tabDidChangeDisplayState(_ tab: Tab)

    /// A committed top-level (main-frame) navigation -- see
    /// EngineTabDelegate.engineTabDidCommitNavigation for exactly what this
    /// does and doesn't cover. This is the history-recording signal.
    func tab(_ tab: Tab, didCommitNavigationTo url: String)

    /// The page reported its title. A navigation commits before its page
    /// has a title, so this is how history learns the real one.
    func tab(_ tab: Tab, didReceiveTitle title: String)

    /// The main-frame URL actually changed -- including a same-document
    /// change (history.pushState), which never reaches
    /// tab(_:didCommitNavigationTo:) above. Not fired for a redundant report
    /// of the URL the tab is already on. This is the "the user is somewhere
    /// else now" signal (TabLifecycleEvent.navigated), as opposed to the
    /// history-recording one.
    func tab(_ tab: Tab, didChangeURLTo url: String)

    /// The main-frame load stopped, whether it succeeded or failed -- see
    /// engineTabDidChangeLoadingState, which draws no distinction either.
    func tabDidFinishLoading(_ tab: Tab)

    func tab(_ tab: Tab, didBeginDownload info: TabDownloadStart)
    func tab(_ tab: Tab, didUpdateDownload info: TabDownloadUpdate)

    /// Mirrors EngineTabDelegate.engineTabDidRequestPermission -- see that
    /// method's doc comment for the promptId/decision contract.
    func tab(_ tab: Tab, didRequestPermission kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void)

    /// Mirrors EngineTabDelegate.engineTabDidDismissPermissionRequest.
    func tab(_ tab: Tab, didDismissPermissionRequestWithId promptId: UInt64)

    /// A target="_blank" link or window.open() call this tab's page made,
    /// resolved to "open as a new tab in this window" -- see
    /// Tab.engineTabDidRequestNewTab for the modifier-key overrides that
    /// decide `foreground` alongside CEF's own reported disposition.
    func tab(_ tab: Tab, didRequestNewTabForURL url: String, foreground: Bool)

    /// Same trigger as above, resolved to "open as a genuine new native
    /// window" instead (a Shift-click override, or CEF's own NEW_WINDOW/
    /// NEW_POPUP disposition -- e.g. an OAuth sign-in flow's window.open()
    /// with explicit size features).
    func tab(_ tab: Tab, didRequestNewWindowForURL url: String)

    /// The engine created `popup` itself for a page-opened window, already
    /// linked to `tab` as its opener -- see EngineTabDelegate.
    /// engineTabDidCreatePopup. Must be adopted synchronously: as a tab in
    /// this window, or as the first tab of a new window when `inNewWindow`.
    func tab(_ tab: Tab, didOpenPopup popup: Tab, inNewWindow: Bool, foreground: Bool)

    /// The page called window.close() -- close exactly this tab.
    func tabDidRequestClose(_ tab: Tab)
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

    /// The profile's stable UUID (browser-ojw) -- what actually scopes this
    /// tab's engine-side cache directory and FaviconLoader's on-disk cache,
    /// as opposed to `profileName` above, which is only used for name-keyed,
    /// in-memory-only mechanisms (content-blocking snapshot lookups) that a
    /// rename simply rebuilds fresh. For a private tab this is the same
    /// throwaway value `profileName` gets -- never actually used to look up
    /// or create real engine-side storage for this tab either, see
    /// createBrowserIfNeeded().
    let profileId: String
    let hostView = NSView()

    /// Splits `hostView` between the page and this tab's developer tools;
    /// the engine draws the page into `devTools.pageView`, not `hostView`.
    private(set) lazy var devTools = DevToolsDockController(hostView: hostView)

    /// This tab's Responsive Design Mode and the device toolbar above its page.
    private(set) lazy var deviceToolbar = DeviceToolbarController(tab: self)

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
    /// Visited tile), and set again when the engine reports one of this
    /// tab's own start pages (going Back to it).
    private(set) var isShowingStartPage: Bool

    /// Payloads of the start pages this tab has loaded (see
    /// StartPageRenderer.payloadKey). Kept so going Back to an earlier start
    /// page, or an engine reporting the data: URL in a re-encoded form, is
    /// still recognised as the start page rather than shown as a raw data:
    /// URL. Newest last, capped.
    private var startPagePayloadKeys: [String] = []

    private(set) var faviconURL: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// The target URL of a main-frame navigation that's been requested but
    /// hasn't committed yet (browser-7z5, Brady's ask: a click should show
    /// feedback instantly, not wait for the real navigation to land). Set
    /// from engineTabWillStartMainFrameNavigation(_:); cleared the moment a
    /// real navigation event supersedes it (loading finishes, whether it
    /// succeeded or failed -- see engineTabDidChangeLoadingState) so it can
    /// never outlive the request it was optimistic about. Purely a display
    /// hint for the omnibox (see BrowserWindowController.
    /// collapsedOmniboxDisplay(for:)/refreshToolbar(for:)) -- urlString
    /// itself is unaffected and stays the tab's real, authoritative address.
    private(set) var pendingNavigationURL: String?

    /// Overall page-loading progress, 0.0-1.0 (browser-7z5) -- mirrors CEF's
    /// own real percentage (see EngineTabDelegate.engineTabDidUpdateLoadingProgress's
    /// own doc comment). Reset to 0 whenever a new main-frame navigation is
    /// requested, so a fresh navigation's progress bar always starts empty
    /// rather than briefly showing the previous page's final value.
    private(set) var loadingProgress: Double = 0

    /// False from the moment a main-frame navigation is requested until this
    /// tab's title next actually changes (browser-7z5) -- lets the tab strip/
    /// toolbar show the target host as a placeholder instead of the
    /// previous page's now-stale title during that window (Brady's report:
    /// "no feedback until it's loaded, then it jumps"). See displayTitle.
    private(set) var hasFreshTitle = true

    /// The last URL that actually committed as a page in this tab, and
    /// whether `engineURLString` is that URL (as opposed to somewhere this
    /// tab was merely *pointed* at, which the engine may never load).
    ///
    /// `engineURLString` is written optimistically -- at init, and again on
    /// every load(url:) -- because the omnibox and tab strip have to show the
    /// destination the instant the user asks for it. A URL that resolves to a
    /// download never commits, so without these two the tab is left parked on
    /// a file URL it never displayed (browser-7ol). See
    /// revertNavigationThatBecameADownload().
    private var lastCommittedURL: String?
    private var isCurrentURLCommitted = false

    /// What the tab strip/toolbar should show as this tab's title right now
    /// (browser-7z5) -- the real title once one has arrived for the current
    /// navigation, otherwise the target host as a placeholder. Falls back to
    /// the real (possibly stale, but better than nothing) title if there's
    /// no URL to derive a host from.
    ///
    /// Always StartPageRenderer.tabTitle while `isShowingStartPage`,
    /// regardless of `hasFreshTitle`/`pendingNavigationURL` -- same
    /// unconditional-while-showing-it pattern as `urlString` above. Without
    /// this, the moment a freshly created start-page tab's own initial
    /// "navigation" to its data: URL is requested, `hasFreshTitle` goes
    /// false and this would otherwise try to derive a host from that data:
    /// URL to show as a placeholder (getting nil, since data: URLs have no
    /// host, and falling through to `title` anyway) -- correct today only
    /// because `title` itself happens to already hold the right value; this
    /// guard makes that guarantee explicit and independent of incidental
    /// URL-parsing behavior, and also holds for a tab transitioning back to
    /// the start page via `load(url:)` on an existing tab.
    var displayTitle: String {
        guard !isShowingStartPage else { return StartPageRenderer.tabTitle }
        guard !hasFreshTitle else { return title }
        let source = pendingNavigationURL ?? urlString
        return URL(string: source)?.host ?? title
    }

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

    /// Number of requests the ad/tracker content blocker has cancelled for
    /// this tab's current page (browser-12m.5.1.1) -- the toolbar badge's
    /// count. Reset to 0 on every navigation (see
    /// engineTabDidStartMainFrameLoad below), same "fresh page, fresh
    /// count" convention as isAudible just above; incremented on the main
    /// thread already (see BRWBrowser.h's
    /// -browserDidBlockRequestToTracker:onPageHost:), so no extra
    /// synchronization is needed here.
    private(set) var blockedRequestCount = 0

    /// The distinct tracker domains blocked on this page load (browser-e7r),
    /// alongside the raw request count above. Two numbers because they
    /// answer two different questions and only one of them may be called
    /// "trackers": a single tracker serving forty requests is one entry here
    /// and forty there. Reset together on every main-frame load.
    private(set) var blockedTrackerDomains: Set<String> = []

    /// This tab's current page zoom, as a scale factor (1.0 == 100%) on
    /// PageZoom's ladder (browser-5kq.15).
    ///
    /// Deliberately *computed from the engine* on every read rather than
    /// cached in a stored property, because zoom is not per-tab state and a
    /// stored copy would silently go stale. Measured, not assumed (see
    /// `bd show browser-5kq.15`): CefBrowserHost::SetZoomLevel writes
    /// into Chromium's HostZoomMap, which is keyed by **host, within the
    /// request context** -- i.e. per host per profile. Zooming one tab
    /// immediately re-scales every other open tab on the same host in the same
    /// profile, with no navigation involved. That is also exactly what Chrome
    /// itself does, so it's the right behaviour as well as the only one CEF's
    /// public API offers; what it rules out is a Swift-side per-tab factor,
    /// which would have started lying the moment a second tab on the same host
    /// existed.
    ///
    /// Consequences worth stating rather than leaving to chance:
    ///
    /// - Zoom **survives navigation** within a tab as long as the host doesn't
    ///   change, and correctly reverts to whatever the *new* host's zoom is
    ///   when it does -- all from the engine, no re-applying on our side.
    /// - A new tab on an un-zoomed host starts at exactly 100%; a new tab on an
    ///   already-zoomed host opens at that host's zoom, matching Chrome.
    /// - Nothing about zoom is written to `session.json` (SessionSnapshot.Tab
    ///   has no zoom field), yet a zoom **does** outlive a relaunch: CEF
    ///   persists HostZoomMap into the profile's own cache_path. Measured, not
    ///   assumed. Surfacing and controlling that (an indicator, a reset-all) is
    ///   the follow-up bead browser-icj.
    var zoomFactor: Double {
        guard let browser else { return PageZoom.defaultFactor }
        return PageZoom.factor(forLevel: browser.zoomLevel())
    }

    /// "100%", "125%" -- for anything that wants to show the current zoom.
    var zoomPercentLabel: String { PageZoom.percentLabel(for: zoomFactor) }

    /// ⌘+ -- one rung up PageZoom's ladder, clamped at the top.
    func zoomIn() { setZoomFactor(PageZoom.stepUp(from: zoomFactor)) }

    /// ⌘− -- one rung down, clamped at the bottom.
    func zoomOut() { setZoomFactor(PageZoom.stepDown(from: zoomFactor)) }

    /// ⌘0 -- exactly 100%, not "the nearest rung to 100%": see
    /// PageZoom.level(forFactor:) for why that distinction reaches the engine.
    func resetZoom() { setZoomFactor(PageZoom.defaultFactor) }

    /// Pushes `factor` to the engine in the logarithmic level units
    /// EngineTab.setZoomLevel(_:) takes. The engine is the only store, so
    /// there is nothing here to keep in sync with it.
    func setZoomFactor(_ factor: Double) {
        browser?.setZoomLevel(PageZoom.level(forFactor: factor))
        delegate?.tabDidChangeDisplayState(self)
    }

    /// Toggles isMuted and immediately applies it to the engine -- the only
    /// place SetAudioMuted is ever called, so isMuted can never drift from
    /// what the engine actually has (no separate "read it back to confirm"
    /// step needed).
    func toggleMuted() {
        guard ActiveEngine.capabilities.perTabAudioMute else { return }
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

    init(profileName: String, profileId: String, initialURL: String, isPrivate: Bool = false) {
        self.profileName = profileName
        self.profileId = profileId
        self.isPrivate = isPrivate
        let resolved = Self.resolveInitialLoad(initialURL, profileId: profileId, isPrivate: isPrivate)
        self.isShowingStartPage = resolved.isStartPage
        self.engineURLString = resolved.url
        self.title = resolved.isStartPage ? StartPageRenderer.tabTitle : initialURL
        super.init()
        hostView.wantsLayer = true
        if resolved.isStartPage { rememberStartPage(resolved.url) }
    }

    /// A tab around a popup the engine already created and is loading --
    /// see TabDelegate.tab(_:didOpenPopup:inNewWindow:foreground:). It
    /// belongs to its opener's profile and privacy mode.
    init(adoptingPopup popup: EnginePopupTab, openedBy opener: Tab) {
        self.profileName = opener.profileName
        self.profileId = opener.profileId
        self.isPrivate = opener.isPrivate
        self.isShowingStartPage = false
        self.engineURLString = ""
        self.title = ""
        super.init()
        hostView.wantsLayer = true
        popup.attach(to: devTools.pageView)
        devTools.attach(to: popup)
        popup.delegate = self
        browser = popup
    }

    private static func resolveInitialLoad(_ requestedURL: String, profileId: String, isPrivate: Bool) -> (url: String, isStartPage: Bool) {
        guard requestedURL == blankPageSentinel || requestedURL.isEmpty
                || StartPageRenderer.isStartPageDataURL(requestedURL) else {
            return (requestedURL, false)
        }
        return (StartPageRenderer.dataURL(profileId: profileId, isPrivate: isPrivate), true)
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
            ? ActiveEngine.createPrivateTab(hostView: devTools.pageView, initialURL: engineURLString)
            : ActiveEngine.createTab(profileName: profileName, profileId: profileId, hostView: devTools.pageView, initialURL: engineURLString)
        browser.delegate = self
        devTools.attach(to: browser)
        self.browser = browser
    }

    func load(url: String) {
        let resolved = Self.resolveInitialLoad(url, profileId: profileId, isPrivate: isPrivate)
        isShowingStartPage = resolved.isStartPage
        engineURLString = resolved.url
        if resolved.isStartPage { rememberStartPage(resolved.url) }
        isCurrentURLCommitted = false
        // Set synchronously rather than waiting for the page's own title
        // event to round-trip back from CEF -- anything reading `title`
        // directly (not just `displayTitle`, which already guards on
        // isShowingStartPage above) sees the right value from this call
        // returning, not one render frame later.
        if resolved.isStartPage {
            title = StartPageRenderer.tabTitle
        }
        if browser == nil {
            createBrowserIfNeeded()
        } else {
            browser?.loadURL(resolved.url)
        }
    }

    /// Re-renders the start page from current settings, for a tab that's
    /// showing it (a no-op for any other tab). Not the same as `reload()`:
    /// StartPageRenderer bakes its HTML into a `data:` URL once, at navigation
    /// time, so reloading that URL faithfully re-displays the *stale* copy --
    /// only navigating again picks up a changed background or section toggle.
    private func rememberStartPage(_ url: String) {
        guard let key = StartPageRenderer.payloadKey(url), !startPagePayloadKeys.contains(key) else { return }
        startPagePayloadKeys.append(key)
        if startPagePayloadKeys.count > 8 { startPagePayloadKeys.removeFirst() }
    }

    private func isOwnStartPage(_ url: String) -> Bool {
        guard let key = StartPageRenderer.payloadKey(url) else { return false }
        return startPagePayloadKeys.contains(key)
    }

    func reloadStartPage() {
        guard isShowingStartPage else { return }
        load(url: Self.blankPageSentinel)
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }


    /// Responsive Design Mode (browser-6hi.2) -- see EngineTab's own doc
    /// comment for why this doesn't need DevTools' own UI open at all.
    func setResponsiveDesignMode(width: Int, height: Int, deviceScaleFactor: Double, mobile: Bool) {
        browser?.setResponsiveDesignMode(width: width, height: height, deviceScaleFactor: deviceScaleFactor, mobile: mobile)
    }

    func clearResponsiveDesignMode() {
        browser?.clearResponsiveDesignMode()
    }

    /// This tab's current CPU usage as a percentage of one core
    /// (browser-7jz.4) -- 0 if there's no engine-side browser yet (matches
    /// EngineTab.cpuUsagePercent()'s own safe-default contract).
    func cpuUsagePercent() -> Double {
        browser?.cpuUsagePercent() ?? 0
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

    func engineTabDidBlockRequest(trackerDomain: String, pageHost: String) {
        blockedRequestCount += 1
        if !trackerDomain.isEmpty {
            blockedTrackerDomains.insert(trackerDomain)
        }
        // The badge above and the privacy report below deliberately count
        // different things: the badge is requests on THIS page load and
        // resets on the next navigation, while the recorder accumulates per
        // day and per tracker domain. See TrackerReportRecorder for why
        // summing badge values would not produce the report's number.
        TrackerReportRecorder.shared.record(
            trackerDomain: trackerDomain,
            pageHost: pageHost,
            profileId: profileId,
            isPrivate: isPrivate
        )
        delegate?.tabDidChangeDisplayState(self)
    }

    /// Set by PageMessageDispatcher, and by nothing else -- it is the single
    /// consumer slot for this tab's raw page messages, which is why one
    /// central dispatcher owns it (see that class's doc comment). A plain
    /// closure property rather than a TabDelegate method for the same reason
    /// as onFindResult just above: these messages are a feature controller's
    /// concern, not the window controller's. `request`
    /// is an opaque string the page passed to `window.cefQuery` -- callers
    /// parse their own payload shape out of it (see BRWBrowser.h's
    /// -browserDidReceivePageMessage:requestId:isMainFrame:frameURL: for the full contract,
    /// including that not calling respondToPageMessage(requestId:...)
    /// exactly once leaves the page's promise pending forever).
    var onPageMessage: ((_ request: String, _ requestId: Int64, _ source: PageMessageSource) -> Void)?

    func engineTabDidReceivePageMessage(_ request: String, requestId: Int64, source: PageMessageSource) {
        onPageMessage?(request, requestId, source)
    }

    /// What PageMessagePolicy cross-checks a page message's sender against.
    /// Carries the engine's real URL, not `urlString`: the start page has to
    /// be recognizable by its exact data: URL.
    var pageMessageTabState: PageMessageTabState {
        PageMessageTabState(engineURL: engineURLString, isShowingStartPage: isShowingStartPage)
    }

    /// "Look Up Image" from the native context menu (browser-5kq.2) --
    /// no per-tab state needed, so this just forwards straight through to
    /// the app-wide controller that fetches/analyzes/presents the result.
    /// In practice this method is never even called pre-macOS 13 (the
    /// context-menu item that triggers it only appears once
    /// ImageAnalyzer.isSupported has already gated it at launch -- see
    /// CEFEngineAdapter.swift's initialize()), but the compiler can't know
    /// that from here, so the macOS-13-only call still needs its own
    /// explicit availability check.
    func engineTabDidRequestVisualLookUp(imageURL: String, pageURL: String) {
        if #available(macOS 13.0, *) {
            VisualLookUpController.handleRequest(imageURL: imageURL, pageURL: pageURL)
        }
    }

    /// "View Page Source" from the native context menu. Opens Chromium's own
    /// source viewer in a foreground tab next to this one, which is where
    /// both Safari and Chrome put it.
    ///
    /// A `view-source:` URL is a real navigation like any other -- it goes
    /// through the same didRequestNewTabForURL: path a ⌘-clicked link uses,
    /// with no special-casing anywhere below this line.
    func engineTabDidRequestViewSource(pageURL: String) {
        guard !pageURL.isEmpty else { return }
        delegate?.tab(self, didRequestNewTabForURL: "view-source:\(pageURL)", foreground: true)
    }

    /// "Copy Image" from the native context menu (browser-5kq.13). Passes
    /// `browser` -- this tab's own EngineTab -- rather than just the URL,
    /// because the bytes must be fetched by the page's own renderer to carry
    /// its cookies; see ImageCopyController's doc comment.
    func engineTabDidRequestCopyImage(imageURL: String, pageURL: String) {
        ImageCopyController.copyImage(imageURL: imageURL, tab: browser)
    }

    /// "Copy Image Link" from the native context menu (browser-5kq.13) --
    /// pure string copy, no per-tab state needed at all.
    func engineTabDidRequestCopyImageLink(imageURL: String) {
        ImageCopyController.copyImageLink(imageURL: imageURL)
    }

    /// "Download Image" from the native context menu (browser-5kq.14). Like
    /// Copy Image this needs `browser` rather than just the URL, so the
    /// download originates from this tab -- which is what makes it both
    /// credentialed and visible in the Downloads window.
    func engineTabDidRequestDownloadImage(imageURL: String) {
        ImageDownloadController.downloadImage(imageURL: imageURL, tab: browser)
    }

    /// Seeds a restored tab's display title immediately at launch, before
    /// its page has even started (re)loading, so the tab strip shows a real
    /// title right away instead of the raw URL -- the real page's own title
    /// arrives later via engineTabDidChangeTitle and naturally overwrites
    /// this. See WindowManager.restoreSession.
    ///
    /// Ignored entirely for a restored start-page tab: `title` is already
    /// correctly StartPageRenderer.tabTitle from `init` above (the
    /// constructor resolves `restoreTab.url` -- always the empty string for
    /// a previously-start-page tab, see `urlString`'s own doc comment --
    /// right back to the start page), and a persisted `title` here could be
    /// stale/wrong for it regardless -- most notably a `session.json` saved
    /// before this fix existed, whose start-page tabs have Chromium's own
    /// title-less-page fallback (the raw data: URL) sitting in this exact
    /// field. Letting that resurface on every future relaunch would make
    /// this fix look broken forever for any such pre-existing session.
    func seedRestoredTitle(_ title: String) {
        guard !isShowingStartPage, !title.isEmpty else { return }
        self.title = title
    }

    func close() {
        devTools.tabWillClose()
        browser?.close()
        browser = nil
    }

    // MARK: - EngineTabDelegate

    func engineTabDidChangeTitle(_ title: String) {
        self.title = title.isEmpty ? urlString : title
        // A real title has arrived for whatever's currently loading (or
        // just finished) -- the placeholder-host display (see
        // displayTitle) no longer applies until the *next* navigation
        // starts. Harmless no-op if this fires outside a navigation.
        hasFreshTitle = true
        delegate?.tabDidChangeDisplayState(self)
        if !title.isEmpty {
            delegate?.tab(self, didReceiveTitle: title)
        }
    }

    func engineTabDidChangeURL(_ url: String) {
        let changed = url != engineURLString
        if changed {
            isShowingStartPage = isOwnStartPage(url)
        }
        engineURLString = url
        delegate?.tabDidChangeDisplayState(self)
        // After the state above is committed, so an observer reading
        // `urlString` from this call already sees the new address. Gated on a
        // real change: CEF re-reports the current URL on some non-navigation
        // events, and the password manager's navigate-away flush treats every
        // one of these as "the user left the page they typed on."
        if changed {
            delegate?.tab(self, didChangeURLTo: urlString)
        }
    }

    func engineTabDidChangeFaviconURL(_ faviconURL: String?) {
        self.faviconURL = faviconURL
        maybeLoadFavicon()
        delegate?.tabDidChangeDisplayState(self)
    }

    func engineTabDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        let didFinishLoading = self.isLoading && !isLoading
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        // Loading has stopped, whether the navigation succeeded or failed --
        // either way, any optimistic pending-navigation display (browser-
        // 7z5) is now stale and must fall back to this tab's real,
        // authoritative urlString. Deliberately not gated on success/
        // failure: a genuine failure never updates urlString/title either,
        // so falling back here already reverts to "whatever was showing
        // before the click" for free, with no separate load-error hook
        // needed.
        if !isLoading {
            pendingNavigationURL = nil
        }
        delegate?.tabDidChangeDisplayState(self)
        if didFinishLoading {
            delegate?.tabDidFinishLoading(self)
        }
    }

    /// Fires the instant a main-frame navigation is requested, before it
    /// commits (browser-7z5, Brady's ask: "no feedback until it's loaded,
    /// then it jumps"). Resets loadingProgress to 0 so a fresh navigation's
    /// progress bar never briefly shows the previous page's final value.
    func engineTabWillStartMainFrameNavigation(_ url: String) {
        // The start page is never shown as an address, so it is never a
        // pending one either.
        pendingNavigationURL = isOwnStartPage(url) ? nil : url
        loadingProgress = 0
        hasFreshTitle = false
        delegate?.tabDidChangeDisplayState(self)
    }

    func engineTabDidUpdateLoadingProgress(_ progress: Double) {
        loadingProgress = progress
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
    /// which PageMessageDispatcher wired at this tab's construction and
    /// routes to whichever feature registered for each message type.
    func engineTabDidStartMainFrameLoad() {
        // A brand-new document hasn't had anything blocked on it yet --
        // reset before the isShowingStartPage guard below so a freshly
        // opened start page tab never shows a stale count left over from
        // whatever real page this tab had before (browser-12m.5.1.1).
        if blockedRequestCount != 0 || !blockedTrackerDomains.isEmpty {
            blockedRequestCount = 0
            blockedTrackerDomains.removeAll()
            delegate?.tabDidChangeDisplayState(self)
        }
        guard !isShowingStartPage else { return }
        executeJavaScript(PasswordDetectionScript.source)
        // Separate script, separate cefQuery message types (browser-ojh.2)
        // -- injected alongside, not merged into, PasswordDetectionScript,
        // so the two features' detection logic stay independently
        // readable/testable even though they share the same delivery
        // mechanism.
        executeJavaScript(PaymentAddressDetectionScript.source)
        // Email suggestions (EmailAutofillCoordinator): its own script and
        // message types, for the email-only sign-in steps neither script
        // above recognizes.
        executeJavaScript(EmailFieldDetectionScript.source)
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
        // Recorded before the start-page guard below: the point of these two
        // is to know whether what the tab is showing is a real, committed page
        // (see revertNavigationThatBecameADownload), and the start page is one.
        // It is nil rather than its own address, though: the start page's
        // giant data: URL is never something to *put back* into the omnibox --
        // reverting to it means rendering the start page again.
        lastCommittedURL = isShowingStartPage ? nil : url
        isCurrentURLCommitted = true
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
        FaviconLoader.shared.loadFavicon(host: host, hintURL: faviconURL, profileId: profileId) { [weak self] image in
            guard let self, self.faviconFetchKey == key else { return }
            self.faviconImage = image
            self.delegate?.tabDidChangeDisplayState(self)
        }
    }

    func engineTabDidBeginDownload(id downloadId: Int64, url: String, suggestedName: String, destinationPath: String) {
        revertNavigationThatBecameADownload(downloadURL: url)
        delegate?.tab(self, didBeginDownload: TabDownloadStart(
            downloadId: downloadId, url: url, suggestedName: suggestedName, destinationPath: destinationPath))
    }

    /// Undoes a navigation that turned out to be a download rather than a
    /// page, so this tab is not left parked on the file's URL (browser-7ol).
    ///
    /// Such a navigation never commits and never renders anything, but
    /// `engineURLString` was already written optimistically when the load was
    /// requested, so the tab keeps showing a URL it never displayed -- and,
    /// worse, that URL goes into session.json and is re-navigated on the next
    /// launch, silently downloading the file a second time with no user
    /// action. Reverting here fixes both: there is no dead tab, and what gets
    /// persisted is the page the tab is really on.
    ///
    /// Two conditions keep this off downloads that a live page started (a
    /// clicked link, a scripted download): the file's URL must be the very URL
    /// this tab was pointed at, and that URL must never have committed. A
    /// download from a real page fails both -- the engine leaves the address
    /// alone for it, exactly as Chrome does.
    private func revertNavigationThatBecameADownload(downloadURL: String) {
        guard !isShowingStartPage, !isCurrentURLCommitted, downloadURL == engineURLString else { return }
        pendingNavigationURL = nil
        if let lastCommittedURL, lastCommittedURL != engineURLString {
            // This tab was showing a real page and was sent to the file URL
            // from there (typed, or opened by the CLI). The engine never left
            // that page, so putting the address back is all that's needed --
            // no reload, and `title` still holds that page's own title.
            engineURLString = lastCommittedURL
            isCurrentURLCommitted = true
            hasFreshTitle = true
        } else {
            // Nothing was ever displayed here: the tab was opened for this URL
            // alone. It becomes an ordinary new tab rather than being closed,
            // which would otherwise mean closing the window when it was the
            // only tab -- a download must not take a window down with it.
            load(url: Self.blankPageSentinel)
        }
        delegate?.tabDidChangeDisplayState(self)
        // tabDidChangeDisplayState is a redraw signal, not a persistence one,
        // and no other event follows a download -- so without this the stale
        // URL can sit in session.json until some unrelated change happens to
        // trigger a save, which is precisely the state that re-downloads.
        WindowManager.shared.scheduleSessionSave()
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

    /// The disposition is authoritative: the engine has already resolved the
    /// click's own modifiers (Cmd -> background tab, Cmd+Shift -> foreground
    /// tab, Shift -> new window, middle-click -> background tab) against the
    /// link's own target. Nothing here reads live keyboard state -- see
    /// docs/ai-tasks/link-click-new-tab-notes.md for why an
    /// NSEvent.modifierFlags query at this point was both wrong (these
    /// callbacks arrive via renderer IPC, a later run-loop turn than the
    /// click) and unnecessary.
    func engineTabDidRequestNewTab(url: String, disposition: EngineWindowOpenDisposition) {
        switch disposition {
        case .foregroundTab:
            delegate?.tab(self, didRequestNewTabForURL: url, foreground: true)
        case .backgroundTab:
            delegate?.tab(self, didRequestNewTabForURL: url, foreground: false)
        case .newWindow, .newPopup:
            delegate?.tab(self, didRequestNewWindowForURL: url)
        }
    }

    func engineTabDidCreatePopup(_ popup: EnginePopupTab, disposition: EngineWindowOpenDisposition) {
        let child = Tab(adoptingPopup: popup, openedBy: self)
        child.needsInitialOmniboxFocus = false
        switch disposition {
        case .foregroundTab:
            delegate?.tab(self, didOpenPopup: child, inNewWindow: false, foreground: true)
        case .backgroundTab:
            delegate?.tab(self, didOpenPopup: child, inNewWindow: false, foreground: false)
        case .newWindow, .newPopup:
            delegate?.tab(self, didOpenPopup: child, inNewWindow: true, foreground: true)
        }
    }

    func engineTabDidRequestClose() {
        delegate?.tabDidRequestClose(self)
    }

    func engineTabDevToolsDidOpen() { devTools.engineDidOpen() }
    func engineTabDevToolsDidClose() { devTools.engineDidClose() }
    func engineTabDevToolsDidRequestDockSide(_ side: DevToolsDockSide) { devTools.engineDidRequestDockSide(side) }
    func engineTabDidRequestInspectElement(at point: NSPoint) { devTools.inspectElement(at: point) }
}
