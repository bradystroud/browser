import AppKit

protocol TabDelegate: AnyObject {
    func tabDidChangeDisplayState(_ tab: Tab)

    /// A committed top-level (main-frame) navigation -- see
    /// BRWEngine.h's -browserDidCommitNavigation: for exactly what this
    /// does and doesn't cover. This is the history-recording signal.
    func tab(_ tab: Tab, didCommitNavigationTo url: String)

    func tab(_ tab: Tab, didBeginDownload info: TabDownloadStart)
    func tab(_ tab: Tab, didUpdateDownload info: TabDownloadUpdate)
}

/// Mirrors BRWEngine.h's -browserDidBeginDownloadWithId:url:suggestedName:
/// destinationPath: -- a plain Swift value so TabDelegate doesn't need to
/// know about the ObjC bridge types.
struct TabDownloadStart {
    let downloadId: Int64
    let url: String
    let suggestedName: String
    let destinationPath: String
}

/// Mirrors BRWEngine.h's -browserDidUpdateDownloadWithId:....
struct TabDownloadUpdate {
    let downloadId: Int64
    let receivedBytes: Int64
    let totalBytes: Int64
    let isComplete: Bool
    let isCancelled: Bool
    let isInterrupted: Bool
}

/// One browser tab: a persistent host NSView + BRWBrowser, plus the
/// navigation/display state the tab strip and omnibox render. The host view
/// is created once and kept alive for the tab's lifetime, including while
/// the tab is not the active one in its window -- switching tabs detaches/
/// reattaches this view from the window's content container rather than
/// destroying and recreating the underlying BRWBrowser (see AppDelegate/
/// BrowserWindowController), matching the plan's requirement that inactive
/// tabs keep their CefBrowser alive.
final class Tab: NSObject, BRWBrowserDelegate {
    let id = UUID()
    let profileName: String
    let hostView = NSView()

    private(set) var browser: BRWBrowser?
    private(set) var title: String
    private(set) var urlString: String
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

    weak var delegate: TabDelegate?

    init(profileName: String, initialURL: String) {
        self.profileName = profileName
        self.urlString = initialURL
        self.title = initialURL
        super.init()
        hostView.wantsLayer = true
    }

    /// Must be called only once `hostView` is attached to a window with a
    /// real frame (CEF's SetAsChild needs real bounds at creation time).
    func createBrowserIfNeeded() {
        guard browser == nil else { return }
        let browser = BRWBrowser(profileName: profileName, hostView: hostView, initialURL: urlString)
        browser.delegate = self
        self.browser = browser
    }

    func load(url: String) {
        urlString = url
        if browser == nil {
            createBrowserIfNeeded()
        } else {
            browser?.loadURL(url)
        }
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }

    // TODO(browser-6hi.1): wire to BRWBrowser.showDevTools()/closeDevTools()
    // (CefBrowserHost::ShowDevTools/CloseDevTools) once that's exposed on the
    // bridge. Blocked for now: BRWBrowser has no file of its own -- it's
    // declared inside BRWEngine.h/.mm, which currently has live, uncommitted
    // work from the quit-crash-fix session, so this session isn't touching
    // it without team-lead sign-off (see docs/ai-tasks/m3-furniture-notes.md's
    // DevTools section). Logs instead of silently no-op'ing so it's obvious
    // in Console.app that the menu item/shortcut reached here but the bridge
    // side isn't wired up yet.
    func showDevTools() {
        NSLog("Browser: DevTools requested for tab %@ -- bridge wiring pending (browser-6hi.1)", urlString)
    }

    func close() {
        browser?.close()
        browser = nil
    }

    // MARK: - BRWBrowserDelegate

    func browserDidChangeTitle(_ title: String) {
        self.title = title.isEmpty ? urlString : title
        delegate?.tabDidChangeDisplayState(self)
    }

    func browserDidChangeURL(_ url: String) {
        urlString = url
        delegate?.tabDidChangeDisplayState(self)
    }

    func browserDidChangeFaviconURL(_ faviconURL: String?) {
        self.faviconURL = faviconURL
        maybeLoadFavicon()
        delegate?.tabDidChangeDisplayState(self)
    }

    func browserDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        delegate?.tabDidChangeDisplayState(self)
    }

    func browserDidCommitNavigation(_ url: String) {
        maybeLoadFavicon()
        delegate?.tab(self, didCommitNavigationTo: url)
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

    func browserDidBeginDownload(withId downloadId: Int64, url: String, suggestedName: String, destinationPath: String) {
        delegate?.tab(self, didBeginDownload: TabDownloadStart(
            downloadId: downloadId, url: url, suggestedName: suggestedName, destinationPath: destinationPath))
    }

    func browserDidUpdateDownload(withId downloadId: Int64, receivedBytes: Int64, totalBytes: Int64, isComplete: Bool, isCancelled: Bool, isInterrupted: Bool) {
        delegate?.tab(self, didUpdateDownload: TabDownloadUpdate(
            downloadId: downloadId, receivedBytes: receivedBytes, totalBytes: totalBytes,
            isComplete: isComplete, isCancelled: isCancelled, isInterrupted: isInterrupted))
    }
}
