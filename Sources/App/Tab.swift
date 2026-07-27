import AppKit

protocol TabDelegate: AnyObject {
    func tabDidChangeDisplayState(_ tab: Tab)
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
        delegate?.tabDidChangeDisplayState(self)
    }

    func browserDidChangeLoadingState(_ isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        delegate?.tabDidChangeDisplayState(self)
    }
}
