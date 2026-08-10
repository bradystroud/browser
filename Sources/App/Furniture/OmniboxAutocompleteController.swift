import AppKit

/// A borderless popup window that never takes key status -- clicks on a
/// suggestion row still deliver normally (any window receives mouse events
/// regardless of key status), but the omnibox's text-field editor keeps
/// first responder the whole time the dropdown is open, matching how
/// Spotlight/Safari-style suggestion popups behave.
private final class AutocompletePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class SuggestionRowView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let urlLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(urlLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let margin: CGFloat = 8
        titleLabel.frame = NSRect(x: margin, y: bounds.height / 2, width: bounds.width - margin * 2, height: bounds.height / 2 - 2)
        urlLabel.frame = NSRect(x: margin, y: 2, width: bounds.width - margin * 2, height: bounds.height / 2 - 2)
    }
}

/// Keyboard-navigable omnibox autocomplete dropdown, fed by
/// HistoryStore.autocomplete(query:) for the window's profile. Owned one per
/// BrowserWindowController; positioned directly under the omnibox field.
///
/// This used to attach the panel with `addChildWindow(_:ordered:)`, which is
/// fatal in this app -- it rebuilds the browser window's whole ordering group
/// and can take an out-of-process `NSRemoteView` down with it, killing the
/// browser (browser-5kq.10; the same call crashed the omnibox start panel on
/// Brady's machine). It's now a standalone panel kept in place by an
/// AnchoredPanelTracker; see that class for the full crash story.
final class OmniboxAutocompleteController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 36
    private static let maxVisibleRows = 6

    private let panel: NSPanel
    private let tableView = NSTableView()
    private(set) var suggestions: [HistorySuggestion] = []
    private var selectedIndex: Int = -1
    private var tracker: AnchoredPanelTracker?
    private weak var anchorField: NSTextField?

    var isVisible: Bool { panel.isVisible }

    /// Called when the user clicks a row directly (bypassing Enter).
    var onCommit: ((HistorySuggestion) -> Void)?

    override init() {
        panel = AutocompletePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hasShadow = true
        // Floats above the browser window by level, not by parenthood
        // (browser-5kq.10).
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        super.init()
        setUpTableView()
    }

    private func setUpTableView() {
        guard let contentView = panel.contentView else { return }
        let scrollView = NSScrollView(frame: contentView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasVerticalScroller = true

        let column = NSTableColumn(identifier: .init("suggestion"))
        column.width = 396
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.selectionHighlightStyle = .regular

        scrollView.documentView = tableView
        panel.contentView = scrollView
    }

    /// Runs `query` against `history` and shows the dropdown positioned
    /// directly below `field` if there are any results; hides it otherwise.
    func update(query: String, history: HistoryStore, below field: NSTextField, in window: NSWindow) {
        guard let results = try? history.autocomplete(query: query, limit: Self.maxVisibleRows), !results.isEmpty else {
            dismiss()
            return
        }
        suggestions = results
        selectedIndex = -1
        tableView.reloadData()
        position(below: field, in: window)
        if !isVisible {
            panel.orderFront(nil)
            anchorField = field
            tracker = AnchoredPanelTracker(
                anchorWindow: window,
                onReposition: { [weak self] in self?.reposition() },
                onDismiss: { [weak self] in self?.dismiss() }
            )
        }
    }

    /// Re-anchors after the browser window moved or resized -- what the old
    /// child-window relationship used to handle implicitly (browser-5kq.10).
    private func reposition() {
        guard isVisible, let field = anchorField, let window = field.window else { return }
        position(below: field, in: window)
    }

    func dismiss() {
        tracker?.stop()
        tracker = nil
        anchorField = nil
        guard isVisible else { return }
        panel.orderOut(nil)
        suggestions = []
        selectedIndex = -1
    }

    /// Moves the highlighted row by `delta` (positive = down), clamped to
    /// the suggestion list, and returns the newly-highlighted suggestion's
    /// URL so the caller can preview it in the omnibox text -- mirrors
    /// standard browser arrow-key-through-suggestions behavior.
    @discardableResult
    func moveSelection(by delta: Int) -> HistorySuggestion? {
        guard !suggestions.isEmpty else { return nil }
        if selectedIndex == -1 {
            selectedIndex = delta > 0 ? 0 : suggestions.count - 1
        } else {
            selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
        }
        tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
        return suggestions[selectedIndex]
    }

    /// The currently arrow-key-highlighted suggestion, if any -- what Enter
    /// should navigate to instead of the omnibox's resolved raw text.
    var highlightedSuggestion: HistorySuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    private func position(below field: NSTextField, in window: NSWindow) {
        let fieldFrameInWindow = field.convert(field.bounds, to: nil)
        let fieldFrameOnScreen = window.convertToScreen(fieldFrameInWindow)
        let rowCount = min(suggestions.count, Self.maxVisibleRows)
        let height = CGFloat(rowCount) * Self.rowHeight
        let origin = NSPoint(x: fieldFrameOnScreen.minX, y: fieldFrameOnScreen.minY - height)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: fieldFrameOnScreen.width, height: height), display: true)
    }

    @objc private func rowClicked() {
        guard tableView.clickedRow >= 0, suggestions.indices.contains(tableView.clickedRow) else { return }
        onCommit?(suggestions[tableView.clickedRow])
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard suggestions.indices.contains(row) else { return nil }
        let suggestion = suggestions[row]
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SuggestionRowView
            ?? SuggestionRowView(frame: .zero)
        view.identifier = identifier
        view.titleLabel.stringValue = suggestion.title.isEmpty ? suggestion.url : suggestion.title
        view.urlLabel.stringValue = suggestion.url
        return view
    }
}
