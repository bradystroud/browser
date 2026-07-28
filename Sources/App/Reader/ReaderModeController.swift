import AppKit

/// Reader mode (browser-5kq.1): a floating "Reader" button that appears
/// when the active tab's page looks article-ish, toggling a client-side
/// Readability.js transformation of the current page. One instance per
/// `BrowserWindow` (see that file's own doc comments for why this owns its
/// floating UI directly rather than anything in `BrowserWindowController`,
/// which was hot with Tab Groups work throughout this task).
///
/// There's no push notification for "the active tab changed" or "the active
/// tab's page finished loading" available without touching
/// `BrowserWindowController`/`TabDelegate` (both off-limits) -- so this
/// polls `activeTab` every 400ms, comparing tab identity + URL + loading
/// state against what it last checked, and only re-runs the (real,
/// non-trivial) readerable check when something actually changed. See
/// docs/ai-tasks/reader-mode-notes.md for why this polling approach was
/// chosen over the alternatives.
final class ReaderModeController: NSObject {
    private static let buttonSize: CGFloat = 26
    /// Must match BrowserWindow/FindBarController's own hardcoded tab-strip
    /// (32) + toolbar (36) height constant -- see
    /// FindBarController.contentTopInset's doc comment for why this is
    /// duplicated rather than shared.
    private static let contentTopInset: CGFloat = 32 + 36

    private weak var window: NSWindow?
    private var buttonView: NSButton?
    private var pollTimer: Timer?

    private weak var lastCheckedTab: Tab?
    private var lastCheckedURL: String?
    private var lastCheckedWasLoading = false

    private var isReaderActive = false
    private weak var activeReaderTab: Tab?

    func attach(to window: NSWindow) {
        self.window = window
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func currentTab() -> Tab? {
        (window?.windowController as? BrowserWindowController)?.activeTab
    }

    private func poll() {
        guard let tab = currentTab() else {
            setButtonVisible(false)
            return
        }

        let tabChanged = tab !== lastCheckedTab
        let urlChanged = tab.urlString != lastCheckedURL
        let finishedLoading = lastCheckedWasLoading && !tab.isLoading
        lastCheckedWasLoading = tab.isLoading

        guard tabChanged || urlChanged || finishedLoading else { return }
        lastCheckedTab = tab
        lastCheckedURL = tab.urlString

        if isReaderActive, tab === activeReaderTab {
            // Don't re-check readerability on our own generated reader page
            // -- document.write already replaced the DOM with our own
            // template, which Readability's heuristic wasn't designed to
            // evaluate, and the button should stay shown (as "active")
            // regardless of what that check would say.
            setButtonVisible(true, active: true)
            return
        }
        if tab.isLoading {
            setButtonVisible(false)
            return
        }
        checkReaderable(for: tab)
    }

    private func checkReaderable(for tab: Tab) {
        guard tab.urlString.hasPrefix("http://") || tab.urlString.hasPrefix("https://") else {
            setButtonVisible(false)
            return
        }
        tab.executeJavaScript(ReaderTemplate.readerableProbeScript)
        // Small settle delay for the fire-and-forget probe script above to
        // actually run in the renderer before reading the page source back
        // -- see docs/ai-tasks/reader-mode-notes.md for why there's no
        // result-path alternative to this wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak tab] in
            guard let self, let tab, tab === self.currentTab() else { return }
            tab.getPageSource { [weak self, weak tab] source in
                guard let self, let tab, tab === self.currentTab() else { return }
                let readerable = source.map(ReaderTemplate.isMarkedReaderable(inSource:)) ?? false
                self.setButtonVisible(readerable)
            }
        }
    }

    // MARK: - Toggle

    @objc func toggle() {
        guard let tab = currentTab() else { return }
        if isReaderActive, tab === activeReaderTab {
            exitReaderMode(for: tab)
        } else {
            enterReaderMode(for: tab)
        }
    }

    private func enterReaderMode(for tab: Tab) {
        tab.executeJavaScript(ReaderTemplate.activationScript(fontScale: ReaderFontSizePreference.current.scale))
        isReaderActive = true
        activeReaderTab = tab
        setButtonVisible(true, active: true)
    }

    private func exitReaderMode(for tab: Tab) {
        isReaderActive = false
        activeReaderTab = nil
        // A real network reload is what actually restores the live page --
        // document.write only ever replaced the in-memory DOM, never
        // navigated away from the original URL.
        tab.reload()
        setButtonVisible(false)
    }

    func setFontSize(_ size: ReaderFontSize) {
        ReaderFontSizePreference.current = size
        guard isReaderActive, let tab = activeReaderTab else { return }
        tab.executeJavaScript(ReaderTemplate.setFontScaleScript(size.scale))
    }

    // MARK: - Floating button

    private func setButtonVisible(_ visible: Bool, active: Bool = false) {
        guard let window, let contentView = window.contentView else { return }
        if buttonView == nil {
            let size = Self.buttonSize
            let button = NSButton(
                image: NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "Reader")!,
                target: self, action: #selector(toggle)
            )
            button.isBordered = false
            button.frame = NSRect(
                x: contentView.bounds.width - size - 12,
                y: contentView.bounds.height - Self.contentTopInset + (36 - size) / 2,
                width: size,
                height: size
            )
            button.autoresizingMask = [.minXMargin, .minYMargin]
            contentView.addSubview(button)
            buttonView = button
        }
        buttonView?.isHidden = !visible
        buttonView?.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
    }
}
