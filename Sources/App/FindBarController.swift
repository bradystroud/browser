import AppKit

/// Compact "Find in Page" bar (⌘F) overlaying the top-right of the web
/// content -- Safari/Chrome-style: a search field, a "N of M" match counter,
/// prev/next chevrons, and a close button. One instance per BrowserWindow
/// (see that file's -toggleFindBar:), created lazily on first use.
///
/// Deliberately owned by `BrowserWindow` rather than `BrowserWindowController`
/// (see Tab.onFindResult's doc comment) -- this class only ever talks to
/// whichever `Tab` is active *at the moment of each action* (resolved fresh
///每次, not cached across the bar's lifetime), so switching tabs while the
/// bar is open doesn't need any extra notification wiring: the next
/// keystroke/Enter/chevron click just operates on whatever tab is now
/// active. The one accepted gap from this: the match counter doesn't
/// instantly clear at the exact moment of a tab switch, only on the next
/// action -- see docs/ai-tasks/find-in-page-notes.md.
final class FindBarController: NSObject, NSTextFieldDelegate {
    private static let barSize = NSSize(width: 320, height: 32)

    private weak var window: NSWindow?
    private var barView: NSView?
    private let searchField = NSTextField()
    private let counterLabel = NSTextField(labelWithString: "")
    private var searchWorkItem: DispatchWorkItem?
    private var lastSearchedText: String?
    private var keyMonitor: Any?

    var isShowing: Bool { barView != nil }

    /// Shows the bar (creating it if needed) and focuses the search field;
    /// if already showing, just re-focuses/selects the field -- matches
    /// Safari/Chrome's ⌘F-while-open behavior of refocusing rather than
    /// toggling closed (Esc/the close button are the only ways to dismiss).
    func show(in window: NSWindow) {
        self.window = window
        if barView == nil {
            buildBar(in: window)
            installKeyMonitor()
        }
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func dismiss() {
        guard let barView else { return }
        searchWorkItem?.cancel()
        currentTab()?.stopFinding(clearSelection: true)
        barView.removeFromSuperview()
        self.barView = nil
        removeKeyMonitor()
    }

    /// Keeps an open bar just inside the content area's top edge when that
    /// edge moves without a window resize (autoresizing only covers resizes).
    func followContentAreaTop() {
        guard let barView, let contentView = window?.contentView else { return }
        let contentAreaTopY = windowController?.contentAreaTopY ?? contentView.bounds.height
        barView.setFrameOrigin(NSPoint(x: barView.frame.minX, y: contentAreaTopY - barView.frame.height - 12))
    }

    private func currentTab() -> Tab? {
        windowController?.activeTab
    }

    private var windowController: BrowserWindowController? {
        window?.windowController as? BrowserWindowController
    }

    // MARK: - View setup

    private func buildBar(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let size = Self.barSize
        let margin: CGFloat = 12
        // NOTE (browser-qpy-overlay-notes): positioning below
        // contentAreaTopY -- i.e. overlapping contentContainerView's own
        // bounds, where CEF's hosted content view lives -- was confirmed
        // during that task to make a plain NSButton invisible regardless of
        // normal AppKit z-order (CEF's compositing surface silently paints
        // over it). This container is layer-backed (wantsLayer below)
        // rather than a plain view, which may or may not composite
        // differently -- not verified either way, since opening the find
        // bar needs a real ⌘F keystroke this task couldn't send under the
        // no-synthetic-input rule. If Brady's manual test finds the find
        // bar doesn't actually appear, this is why -- see
        // ReaderModeController.setButtonVisible for the toolbar-row
        // placement that's confirmed to render.
        let contentAreaTopY = windowController?.contentAreaTopY ?? contentView.bounds.height
        let container = NSView(frame: NSRect(
            x: contentView.bounds.width - size.width - margin,
            y: contentAreaTopY - size.height - margin,
            width: size.width,
            height: size.height
        ))
        container.autoresizingMask = [.minXMargin, .minYMargin]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let fieldMargin: CGFloat = 8
        let buttonSize: CGFloat = 20
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Done")!, target: self, action: #selector(closeTapped))
        closeButton.isBordered = false
        closeButton.frame = NSRect(x: size.width - fieldMargin - buttonSize, y: (size.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        closeButton.autoresizingMask = [.minXMargin]
        container.addSubview(closeButton)

        let nextButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: self, action: #selector(nextTapped))
        nextButton.isBordered = false
        nextButton.frame = NSRect(x: closeButton.frame.minX - 4 - buttonSize, y: (size.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        nextButton.autoresizingMask = [.minXMargin]
        container.addSubview(nextButton)

        let prevButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: self, action: #selector(previousTapped))
        prevButton.isBordered = false
        prevButton.frame = NSRect(x: nextButton.frame.minX - 4 - buttonSize, y: (size.height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        prevButton.autoresizingMask = [.minXMargin]
        container.addSubview(prevButton)

        let counterWidth: CGFloat = 64
        counterLabel.frame = NSRect(x: prevButton.frame.minX - counterWidth, y: 0, width: counterWidth, height: size.height)
        counterLabel.alignment = .right
        counterLabel.font = .systemFont(ofSize: 11)
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.autoresizingMask = [.minXMargin]
        container.addSubview(counterLabel)

        searchField.frame = NSRect(x: fieldMargin, y: 4, width: counterLabel.frame.minX - fieldMargin - 4, height: size.height - 8)
        searchField.placeholderString = "Find in Page"
        searchField.autoresizingMask = [.width]
        searchField.delegate = self
        container.addSubview(searchField)

        contentView.addSubview(container)
        barView = container
    }

    // MARK: - Search triggering

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch(for: searchField.stringValue)
    }

    private func scheduleSearch(for text: String) {
        searchWorkItem?.cancel()
        guard !text.isEmpty else {
            lastSearchedText = nil
            currentTab()?.stopFinding(clearSelection: true)
            updateCounter(matchCount: 0, activeMatchOrdinal: 0)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSearch(text: text, forward: true)
        }
        searchWorkItem = workItem
        // ~150ms debounce for live-search-as-you-type (browser-5kq.5's scope).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func performSearch(text: String, forward: Bool) {
        guard let tab = currentTab() else { return }
        // Searching again with the same text is a "find next/previous" of
        // the same ongoing search; new text is always a fresh search (CEF
        // restarts automatically on a searchText change regardless of this
        // flag, but matching the intent explicitly here too).
        let isRepeat = text == lastSearchedText
        tab.onFindResult = { [weak self] matchCount, activeMatchOrdinal, _ in
            self?.updateCounter(matchCount: matchCount, activeMatchOrdinal: activeMatchOrdinal)
        }
        tab.find(text, forward: forward, matchCase: false, findNext: isRepeat)
        lastSearchedText = text
    }

    private func updateCounter(matchCount: Int, activeMatchOrdinal: Int) {
        if matchCount == 0 {
            counterLabel.stringValue = lastSearchedText == nil ? "" : "No Results"
        } else {
            counterLabel.stringValue = "\(activeMatchOrdinal) of \(matchCount)"
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss()
    }

    @objc private func nextTapped() {
        findNext()
    }

    @objc private func previousTapped() {
        findPrevious()
    }

    private func findNext() {
        searchWorkItem?.cancel()
        let text = searchField.stringValue
        guard !text.isEmpty else { return }
        performSearch(text: text, forward: true)
    }

    private func findPrevious() {
        searchWorkItem?.cancel()
        let text = searchField.stringValue
        guard !text.isEmpty else { return }
        performSearch(text: text, forward: false)
    }

    // MARK: - Keyboard (Enter/Shift+Enter/Escape)

    /// A local monitor rather than control(_:textView:doCommandBy:) because
    /// that delegate method can't distinguish plain Return from Shift+Return
    /// (both normally resolve to the same insertNewline: selector) -- same
    /// "local NSEvent monitor for a specific overlay's keyboard handling"
    /// pattern already used by ShortcutsOverlayController/TabCyclingController.
    /// Scoped to only intercept when the search field itself is first
    /// responder, so it never steals keys meant for the web page or omnibox.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isSearchFieldFocused(in: event) else { return event }
            switch event.keyCode {
            case 53:  // Escape
                self.dismiss()
                return nil
            case 36, 76:  // Return, numpad Enter
                if event.modifierFlags.contains(.shift) {
                    self.findPrevious()
                } else {
                    self.findNext()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func isSearchFieldFocused(in event: NSEvent) -> Bool {
        guard let window = event.window ?? self.window else { return false }
        guard let editor = searchField.currentEditor() else { return false }
        return window.firstResponder === editor
    }
}
