import AppKit

/// One row of the email suggestion popup.
struct EmailSuggestionRow: Equatable {
    let email: String
    /// The row's second line: why it is first, or where it came from.
    let detail: String
}

/// Never takes key status, like the omnibox dropdown's panel: the page's
/// field keeps focus while the popup is open, and clicks on a row still
/// arrive (any window receives mouse events regardless of key status).
private final class EmailSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class EmailSuggestionRowView: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)
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
        iconView.frame = NSRect(x: margin, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let textX = margin + iconSize + margin
        let textWidth = max(bounds.width - textX - margin, 0)
        if detailLabel.stringValue.isEmpty {
            titleLabel.frame = NSRect(x: textX, y: (bounds.height - 18) / 2, width: textWidth, height: 18)
        } else {
            titleLabel.frame = NSRect(x: textX, y: bounds.height / 2, width: textWidth, height: bounds.height / 2 - 2)
        }
        detailLabel.frame = NSRect(x: textX, y: 2, width: textWidth, height: bounds.height / 2 - 2)
    }
}

/// The dropdown under a focused email field -- the omnibox dropdown's look
/// (same row layout, corner radius and hairline border), hung from a field
/// inside the page instead of from the omnibox. A child window of the
/// browser window, so it moves and closes with it.
///
/// Keyboard: while it is visible, a local key-down monitor takes ↑/↓,
/// Return and Esc before the engine sees them, but only while the page (not
/// the omnibox or any other control) has keyboard focus -- every other key
/// goes to the page as usual, and the page's own input events refilter the
/// list.
final class EmailSuggestionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 36
    private static let cornerRadius: CGFloat = 10
    private static let anchorGap: CGFloat = 2
    private static let minimumWidth: CGFloat = 260

    private let panel: NSPanel
    private let tableView = NSTableView()
    private(set) var rows: [EmailSuggestionRow] = []
    private var selectedIndex = -1
    private var keyMonitor: Any?
    private weak var parentWindow: NSWindow?
    /// The view keyboard focus must be inside for the key monitor to act.
    private weak var focusContainer: NSView?

    var onChoose: ((EmailSuggestionRow) -> Void)?
    var onDismissByUser: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = EmailSuggestionPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        super.init()

        let scrollView = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasVerticalScroller = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = Self.cornerRadius
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor

        let column = NSTableColumn(identifier: .init("email"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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

    /// Shows `rows` under `fieldRectOnScreen`, or hides the popup when there
    /// are none. The selection resets whenever the list itself changes.
    func show(rows newRows: [EmailSuggestionRow], below fieldRectOnScreen: NSRect, in window: NSWindow, focusContainer: NSView) {
        guard !newRows.isEmpty else {
            dismiss()
            return
        }
        if newRows != rows { selectedIndex = -1 }
        rows = newRows
        self.focusContainer = focusContainer
        tableView.reloadData()
        if selectedIndex >= 0 {
            tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }

        let width = max(fieldRectOnScreen.width, Self.minimumWidth)
        let height = CGFloat(rows.count) * Self.rowHeight
        var frame = NSRect(x: fieldRectOnScreen.minX, y: fieldRectOnScreen.minY - Self.anchorGap - height, width: width, height: height)
        // Flip above the field when there is no room below it on screen.
        if let screen = window.screen ?? NSScreen.main, frame.minY < screen.visibleFrame.minY {
            frame.origin.y = fieldRectOnScreen.maxY + Self.anchorGap
        }
        panel.setFrame(frame, display: true)
        tableView.tableColumns.first?.width = width

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        parentWindow = window
        if !panel.isVisible { panel.orderFront(nil) }
        installKeyMonitor()
    }

    func dismiss() {
        removeKeyMonitor()
        rows = []
        selectedIndex = -1
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Whether `event` was one of ours. Only while the page has focus: the
    /// same keys in the omnibox or a sheet belong to them.
    private func handle(_ event: NSEvent) -> Bool {
        guard panel.isVisible, !rows.isEmpty, let window = parentWindow, event.window === window,
              let container = focusContainer,
              let responder = window.firstResponder as? NSView, responder.isDescendant(of: container)
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125: // down
            moveSelection(by: 1)
            return true
        case 126: // up
            moveSelection(by: -1)
            return true
        case 36, 76: // return, keypad enter
            guard rows.indices.contains(selectedIndex) else { return false }
            onChoose?(rows[selectedIndex])
            return true
        case 53: // escape
            dismiss()
            onDismissByUser?()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        if selectedIndex == -1 {
            selectedIndex = delta > 0 ? 0 : rows.count - 1
        } else {
            selectedIndex = (selectedIndex + delta + rows.count) % rows.count
        }
        tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    @objc private func rowClicked() {
        guard rows.indices.contains(tableView.clickedRow) else { return }
        onChoose?(rows[tableView.clickedRow])
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("emailRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? EmailSuggestionRowView
            ?? EmailSuggestionRowView(frame: .zero)
        view.identifier = identifier
        view.titleLabel.stringValue = rows[row].email
        view.detailLabel.stringValue = rows[row].detail
        view.needsLayout = true
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A click selects before its action fires; keep arrow-key state in step.
        if tableView.selectedRow >= 0 { selectedIndex = tableView.selectedRow }
    }
}
