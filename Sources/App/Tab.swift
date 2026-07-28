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

    private(set) var browser: EngineTab?
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
        let browser = ActiveEngine.createTab(profileName: profileName, hostView: hostView, initialURL: urlString)
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

    func showDevTools() { browser?.showDevTools() }
    func closeDevTools() { browser?.closeDevTools() }

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
        urlString = url
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

    func engineTabDidCommitNavigation(_ url: String) {
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
