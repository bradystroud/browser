import AppKit

/// Compact "Find in Page" bar (⌘F) floating over the top-right of the web
/// content -- Safari/Chrome-style: a search field, a "N of M" match counter,
/// prev/next chevrons, and a close button, drawn in the same glass pill the
/// omnibox uses. One instance per BrowserWindow (see that file's
/// -toggleFindBar:), created lazily on first use.
///
/// Deliberately owned by `BrowserWindow` rather than `BrowserWindowController`
/// (see Tab.onFindResult's doc comment) -- this class only ever talks to
/// whichever `Tab` is active *at the moment of each action*, resolved fresh
/// rather than cached across the bar's lifetime, so switching tabs while the
/// bar is open doesn't need any extra notification wiring: the next
/// keystroke/Enter/chevron click just operates on whatever tab is now
/// active. The one accepted gap from this: the match counter doesn't
/// instantly clear at the exact moment of a tab switch, only on the next
/// action.
///
/// The bar is a subview of `window.contentView`, added after (so above) the
/// web content container. Both engines' page views are ordinary layer-backed
/// descendants of that container, so plain AppKit sibling z-order puts the
/// bar on top of the page.
final class FindBarController: NSObject, NSTextFieldDelegate {
    private static let barWidth: CGFloat = 360
    private static let barHeight: CGFloat = 36
    /// The omnibox pill's own radius (its 30pt height / 2, see
    /// BrowserWindowController.omniboxContainerView), so both floating pills
    /// read as one family.
    private static let cornerRadius: CGFloat = 15
    /// Gap between the bar and the page area's top and trailing edges.
    private static let edgeMargin: CGFloat = 10
    private static let controlSize: CGFloat = 28
    private static let symbolPointSize: CGFloat = 12

    private weak var window: NSWindow?
    private var barView: GlassBackgroundView?
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
        barView.frame = barFrame(in: contentView)
    }

    private func currentTab() -> Tab? {
        windowController?.activeTab
    }

    private var windowController: BrowserWindowController? {
        window?.windowController as? BrowserWindowController
    }

    // MARK: - View setup

    /// Top-right of the page area. The page area's trailing edge is always
    /// the window's (the vertical tab sidebar sits on the leading side), so
    /// only its top edge needs asking for.
    private func barFrame(in contentView: NSView) -> NSRect {
        let contentAreaTopY = windowController?.contentAreaTopY ?? contentView.bounds.height
        return NSRect(
            x: contentView.bounds.width - Self.barWidth - Self.edgeMargin,
            y: contentAreaTopY - Self.barHeight - Self.edgeMargin,
            width: Self.barWidth,
            height: Self.barHeight
        )
    }

    private func buildBar(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let bar = GlassBackgroundView(
            material: .hudWindow, blendingMode: .withinWindow,
            solidFallbackColor: .controlBackgroundColor,
            cornerRadius: Self.cornerRadius
        )
        bar.frame = barFrame(in: contentView)
        bar.autoresizingMask = [.minXMargin, .minYMargin]
        // Same hairline edge as the omnibox pill -- it is what separates the
        // glass from a white page behind it.
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor.separatorColor.cgColor

        // Children go in contentContainer, never `bar` itself -- see
        // GlassBackgroundView.contentContainer.
        let content = bar.contentContainer
        let size = bar.frame.size
        let inset: CGFloat = 4
        let controlY = (size.height - Self.controlSize) / 2

        let closeButton = makeButton(symbol: "xmark", label: "Close", action: #selector(closeTapped))
        closeButton.frame = NSRect(x: size.width - inset - Self.controlSize, y: controlY, width: Self.controlSize, height: Self.controlSize)
        content.addSubview(closeButton)

        let nextButton = makeButton(symbol: "chevron.down", label: "Next Match (⌘G)", action: #selector(nextTapped))
        nextButton.frame = closeButton.frame.offsetBy(dx: -Self.controlSize, dy: 0)
        content.addSubview(nextButton)

        let prevButton = makeButton(symbol: "chevron.up", label: "Previous Match (⇧⌘G)", action: #selector(previousTapped))
        prevButton.frame = nextButton.frame.offsetBy(dx: -Self.controlSize, dy: 0)
        content.addSubview(prevButton)

        let labelFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading) + 2

        let counterWidth: CGFloat = 76
        counterLabel.frame = NSRect(
            x: prevButton.frame.minX - 4 - counterWidth,
            y: (size.height - labelHeight) / 2,
            width: counterWidth,
            height: labelHeight
        )
        counterLabel.alignment = .right
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        counterLabel.textColor = .secondaryLabelColor
        counterLabel.lineBreakMode = .byClipping
        content.addSubview(counterLabel)

        let fieldX: CGFloat = 14
        searchField.frame = NSRect(
            x: fieldX,
            y: (size.height - labelHeight) / 2,
            width: counterLabel.frame.minX - fieldX - 4,
            height: labelHeight
        )
        searchField.font = labelFont
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.placeholderString = "Find in Page"
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        content.addSubview(searchField)

        contentView.addSubview(bar)
        barView = bar
    }

    /// Borderless until hovered, like the reload button inside the omnibox
    /// pill -- a bezel on each would read as bubbles inside a bubble.
    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.applyChromeAppearance(.inline)
        button.imageScaling = .scaleNone
        button.toolTip = label
        return button
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
        // ~150ms debounce for live-search-as-you-type.
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

    // MARK: - Keyboard (Return/⇧Return, Esc, ⌘G/⇧⌘G)

    /// A local monitor rather than control(_:textView:doCommandBy:) because
    /// that delegate method can't distinguish plain Return from Shift+Return
    /// (both normally resolve to the same insertNewline: selector) -- same
    /// "local NSEvent monitor for a specific overlay's keyboard handling"
    /// pattern already used by ShortcutsOverlayController/TabCyclingController.
    ///
    /// Return/Esc are only taken while the search field itself is first
    /// responder, so they never steal keys meant for the web page or
    /// omnibox. ⌘G/⇧⌘G are taken anywhere in this window while the bar is
    /// open (so they also work after clicking back into the page), and have
    /// no menu item of their own to collide with.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isFindAgainChord(event) {
                if event.modifierFlags.contains(.shift) {
                    self.findPrevious()
                } else {
                    self.findNext()
                }
                return nil
            }
            guard self.isSearchFieldFocused(in: event) else { return event }
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

    private func isFindAgainChord(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "g"
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
