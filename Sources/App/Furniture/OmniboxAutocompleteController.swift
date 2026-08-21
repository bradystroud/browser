import AppKit

/// One row of the omnibox dropdown, whatever produced it.
struct OmniboxSuggestion: Equatable {
    enum Kind: Equatable {
        /// A page already in this profile's history.
        case history
        /// A Quick Website Search: search a site the user has searched before.
        case quickSite
        /// Run the typed text as a search with the selected engine.
        case search
        /// A live suggestion from the engine's suggestion endpoint.
        case engineSuggestion
    }

    let kind: Kind
    /// The row's first line.
    let title: String
    /// The row's second line -- the URL for a history row, and what the row
    /// will do for the others.
    let detail: String
    /// Where Return (or a click) navigates. Always absolute.
    let url: String
    /// What the omnibox field shows while this row is arrow-key highlighted.
    /// A search row previews the query rather than the engine's URL, which
    /// is what the user would want to edit and re-run.
    let editText: String
}

/// A borderless popup window that never takes key status -- clicks on a
/// suggestion row still deliver normally (any window receives mouse events
/// regardless of key status), but the omnibox's text-field editor keeps
/// first responder the whole time the dropdown is open, matching how
/// Spotlight/Safari-style suggestion popups behave.
private final class AutocompletePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class SuggestionRowView: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let margin: CGFloat = 8
        let iconSize: CGFloat = 16
        iconView.frame = NSRect(
            x: margin, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize
        )
        let textX = margin + iconSize + margin
        let textWidth = max(bounds.width - textX - margin, 0)
        titleLabel.frame = NSRect(x: textX, y: bounds.height / 2, width: textWidth, height: bounds.height / 2 - 2)
        detailLabel.frame = NSRect(x: textX, y: 2, width: textWidth, height: bounds.height / 2 - 2)
    }
}

/// Keyboard-navigable omnibox dropdown. Merges this profile's history
/// (HistoryStore.autocomplete) with a Quick Website Search row, a "search
/// with the selected engine" row, and -- only when the user has opted in and
/// the window is not private -- live suggestions from the engine
/// (browser-0du). Owned one per BrowserWindowController; positioned as a
/// child window directly under the omnibox field so it moves/closes with the
/// parent window automatically.
final class OmniboxAutocompleteController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 36
    private static let maxVisibleRows = 8
    /// History rows shrink to leave room once engine suggestions arrive, so
    /// a full dropdown still shows some of each rather than all of one.
    private static let historyLimit = 5
    private static let historyLimitWithSuggestions = 3
    private static let engineSuggestionLimit = 3

    /// Everything the row list is rebuilt from, kept so a suggestion
    /// response that lands after the keystroke can rebuild without asking
    /// the database again.
    private struct Context {
        let query: String
        let history: [HistorySuggestion]
        let quickMatch: QuickSiteSearchMatch?
        let engine: SearchEngine
        let searchURL: String?
        weak var field: NSTextField?
        weak var window: NSWindow?
    }

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let fetcher = SearchSuggestionFetcher()
    private var context: Context?
    private var engineSuggestions: [String] = []
    private(set) var suggestions: [OmniboxSuggestion] = []
    private var selectedIndex: Int = -1

    var isVisible: Bool { panel.isVisible }

    /// Called when the user clicks a row directly (bypassing Enter).
    var onCommit: ((OmniboxSuggestion) -> Void)?

    override init() {
        panel = AutocompletePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
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

    /// Rebuilds the dropdown for `query` and shows it below `field`, or
    /// hides it when nothing is worth showing. Engine suggestions, when they
    /// are allowed at all, arrive later and refresh the rows in place.
    func update(query: String, history: HistoryStore, below field: NSTextField, in window: NSWindow) {
        fetcher.cancel()
        engineSuggestions = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }

        let owner = window.windowController as? BrowserWindowController
        let engine = SearchEnginePreference.current
        let historyResults = (try? history.autocomplete(query: trimmed, limit: Self.historyLimit)) ?? []
        let quickSites = owner.map { OmniboxSubmission.quickSites(for: $0.profile) } ?? []

        var quickMatch: QuickSiteSearchMatch?
        var searchURL: String?
        if case .search(let terms) = OmniboxInputClassifier.classify(trimmed) {
            quickMatch = QuickSiteSearch.match(input: terms, sites: quickSites)
            searchURL = engine.searchURL(for: terms)
        }

        context = Context(
            query: trimmed,
            history: historyResults,
            quickMatch: quickMatch,
            engine: engine,
            searchURL: searchURL,
            field: field,
            window: window
        )
        render()

        if searchURL != nil, suggestionsAllowed(for: owner) {
            fetcher.fetch(query: trimmed, engine: engine) { [weak self] terms in
                self?.applyEngineSuggestions(terms, for: trimmed)
            }
        }
    }

    /// The single gate on sending keystrokes to a search engine
    /// (browser-0du). Both halves have to hold, and it fails closed: a
    /// window this controller cannot positively identify as a non-private
    /// browser window gets no suggestions rather than the benefit of the
    /// doubt.
    private func suggestionsAllowed(for owner: BrowserWindowController?) -> Bool {
        guard SearchEnginePreference.suggestionsEnabled else { return false }
        guard let owner else { return false }
        return !owner.isPrivate
    }

    private func applyEngineSuggestions(_ terms: [String], for query: String) {
        guard let context, context.query == query else { return }
        // Leave the rows alone once the user has started arrowing through
        // them: inserting rows underneath a highlighted one would move the
        // selection to something they never chose.
        guard selectedIndex == -1 else { return }
        engineSuggestions = terms
        render()
    }

    private func render() {
        guard let context, let field = context.field, let window = context.window else {
            dismiss()
            return
        }
        suggestions = buildRows(context: context)
        guard !suggestions.isEmpty else {
            dismiss()
            return
        }
        selectedIndex = -1
        tableView.reloadData()
        position(below: field, in: window)
        if !isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    /// Row order: the site keyword first (it is the most specific thing the
    /// input can mean), then history, then the search the engine would run,
    /// then that engine's own suggestions -- so the "search with" row reads
    /// as the heading for the suggestions beneath it.
    private func buildRows(context: Context) -> [OmniboxSuggestion] {
        var rows: [OmniboxSuggestion] = []

        if let match = context.quickMatch {
            rows.append(OmniboxSuggestion(
                kind: .quickSite,
                title: match.query,
                detail: "Search \(match.site.host)",
                url: match.url,
                editText: context.query
            ))
        }

        let historyLimit = engineSuggestions.isEmpty ? Self.historyLimit : Self.historyLimitWithSuggestions
        for entry in context.history.prefix(historyLimit) {
            rows.append(OmniboxSuggestion(
                kind: .history,
                title: entry.title.isEmpty ? entry.url : entry.title,
                detail: entry.url,
                url: entry.url,
                editText: entry.url
            ))
        }

        if let searchURL = context.searchURL {
            rows.append(OmniboxSuggestion(
                kind: .search,
                title: context.query,
                detail: "Search with \(context.engine.name)",
                url: searchURL,
                editText: context.query
            ))
        }

        for term in engineSuggestions.prefix(Self.engineSuggestionLimit) {
            guard let url = context.engine.searchURL(for: term) else { continue }
            rows.append(OmniboxSuggestion(
                kind: .engineSuggestion,
                title: term,
                detail: "\(context.engine.name) Suggestion",
                url: url,
                editText: term
            ))
        }

        return Array(rows.prefix(Self.maxVisibleRows))
    }

    func dismiss() {
        fetcher.cancel()
        context = nil
        engineSuggestions = []
        guard isVisible else {
            suggestions = []
            selectedIndex = -1
            return
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        suggestions = []
        selectedIndex = -1
    }

    /// Moves the highlighted row by `delta` (positive = down), clamped to
    /// the suggestion list, and returns the newly-highlighted suggestion so
    /// the caller can preview its `editText` in the omnibox -- mirrors
    /// standard browser arrow-key-through-suggestions behavior.
    @discardableResult
    func moveSelection(by delta: Int) -> OmniboxSuggestion? {
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
    var highlightedSuggestion: OmniboxSuggestion? {
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

    private static func symbolName(for kind: OmniboxSuggestion.Kind) -> String {
        switch kind {
        case .history: return "clock"
        case .quickSite: return "globe"
        case .search, .engineSuggestion: return "magnifyingglass"
        }
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
        view.iconView.image = NSImage(
            systemSymbolName: Self.symbolName(for: suggestion.kind), accessibilityDescription: nil
        )
        view.titleLabel.stringValue = suggestion.title
        view.detailLabel.stringValue = suggestion.detail
        return view
    }
}
