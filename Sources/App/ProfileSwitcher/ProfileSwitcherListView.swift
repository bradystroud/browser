import AppKit

/// The profile quick-switcher's list (browser-sdj.2): one row per profile,
/// each a colour dot plus its name, with the keyboard handling that makes the
/// panel usable without ever reaching for the mouse -- ↑/↓ move the
/// selection (wrapping, like Ctrl+Tab's tab cycling), Return commits, Escape
/// cancels, and typing filters by name.
///
/// Drawn entirely in one `draw(_:)` rather than as per-row subviews: a row
/// here has no state of its own (no controls, no hover behaviour), and
/// filtering rebuilds the visible set on every keystroke, so a redraw plus a
/// height callback is far less machinery than creating and destroying row
/// views. Hit-testing is a single divide in `mouseDown`.
final class ProfileSwitcherListView: NSView {
    struct Item {
        let profile: Profile
        /// A window for this profile is already open, so committing focuses
        /// that window instead of opening a second one (see
        /// ProfileSwitcherController.commit). Shown as a row tag so the
        /// difference is visible *before* pressing Return, rather than being
        /// a surprise afterwards.
        let hasOpenWindow: Bool
    }

    static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 34
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 12
    private static let headerHeight: CGFloat = 16
    private static let headerGap: CGFloat = 8
    private static let footerGap: CGFloat = 10
    private static let footerHeight: CGFloat = 14
    private static let dotDiameter: CGFloat = 10

    /// Every profile, unfiltered -- `items` is whatever the current `query`
    /// leaves of it.
    private let allItems: [Item]
    private var items: [Item]
    private var selectedIndex: Int
    private var query = ""

    var onCommit: ((Profile) -> Void)?
    var onCancel: (() -> Void)?
    /// Filtering changes the row count, and the panel is sized exactly to its
    /// content -- the controller resizes the window (keeping its top edge
    /// fixed) in response.
    var onHeightChange: ((CGFloat) -> Void)?

    init(items: [Item], selectedIndex: Int) {
        self.allItems = items
        self.items = items
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        frame.size.height = Self.height(forRowCount: items.count)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A filtered-to-nothing list still reserves one row's worth of space for
    /// its "no matches" message, so the panel never collapses to a sliver.
    static func height(forRowCount rowCount: Int) -> CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return verticalPadding + headerHeight + headerGap
            + rows * rowHeight + footerGap + footerHeight + verticalPadding
    }

    private var rowsTop: CGFloat { Self.verticalPadding + Self.headerHeight + Self.headerGap }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:  // Down
            moveSelection(by: 1)
        case 126:  // Up
            moveSelection(by: -1)
        case 36, 76:  // Return, numpad Enter
            commitSelection()
        case 53:  // Escape
            onCancel?()
        case 51:  // Delete
            guard !query.isEmpty else { return }
            query.removeLast()
            applyQuery()
        default:
            guard let typed = event.characters, !typed.isEmpty,
                  !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return }
            query += typed
            applyQuery()
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        needsDisplay = true
    }

    private func commitSelection() {
        guard items.indices.contains(selectedIndex) else { return }
        onCommit?(items[selectedIndex].profile)
    }

    /// Case- and diacritic-insensitive substring match on the profile name --
    /// the only text a row shows, so it's the only thing worth matching.
    /// Selection resets to the top of the new result set rather than trying
    /// to follow the previously selected profile: after typing, the first
    /// match is what the user is aiming at.
    private func applyQuery() {
        items = query.isEmpty
            ? allItems
            : allItems.filter { $0.profile.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        selectedIndex = 0
        let newHeight = Self.height(forRowCount: items.count)
        if newHeight != frame.height {
            frame.size.height = newHeight
            onHeightChange?(newHeight)
        }
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else { return }
        selectedIndex = index
        needsDisplay = true
    }

    /// Committing on mouse *up* (having selected on mouse down) matches how
    /// every other list in this app behaves -- a press that drags off the row
    /// before releasing shouldn't open a window.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point), index == selectedIndex else { return }
        commitSelection()
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        guard !items.isEmpty, point.y >= rowsTop else { return nil }
        let index = Int((point.y - rowsTop) / Self.rowHeight)
        return items.indices.contains(index) ? index : nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawHeader()
        if items.isEmpty {
            drawEmptyState()
        } else {
            for (index, item) in items.enumerated() {
                drawRow(item, at: index, isSelected: index == selectedIndex)
            }
        }
        drawFooter()
    }

    private func drawHeader() {
        let text = query.isEmpty ? "Switch Profile" : "Switch Profile — \(query)"
        draw(text, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor,
             at: NSPoint(x: Self.horizontalPadding + 4, y: Self.verticalPadding))
    }

    private func drawFooter() {
        let y = frame.height - Self.verticalPadding - Self.footerHeight
        draw("↑↓ select · ⏎ open · esc cancel", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor,
             at: NSPoint(x: Self.horizontalPadding + 4, y: y))
    }

    private func drawEmptyState() {
        draw("No profiles match", font: .systemFont(ofSize: 13), color: .tertiaryLabelColor,
             at: NSPoint(x: Self.horizontalPadding + 4, y: rowsTop + 8))
    }

    private func drawRow(_ item: Item, at index: Int, isSelected: Bool) {
        let rowRect = NSRect(
            x: Self.horizontalPadding,
            y: rowsTop + CGFloat(index) * Self.rowHeight,
            width: frame.width - Self.horizontalPadding * 2,
            height: Self.rowHeight
        )

        if isSelected {
            let highlight = rowRect.insetBy(dx: 0, dy: 2)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 8, yRadius: 8).fill()
        }

        let dotRect = NSRect(
            x: rowRect.minX + 10,
            y: rowRect.midY - Self.dotDiameter / 2,
            width: Self.dotDiameter,
            height: Self.dotDiameter
        )
        (NSColor(hex: item.profile.colorHex) ?? .controlAccentColor).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let nameFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let nameColor: NSColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        draw(item.profile.name, font: nameFont, color: nameColor,
             at: NSPoint(x: dotRect.maxX + 10, y: rowRect.midY - nameFont.pointSize * 0.75))

        guard item.hasOpenWindow else { return }
        let tagFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let tagColor: NSColor = isSelected ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        let tagSize = size(of: "Open", font: tagFont)
        draw("Open", font: tagFont, color: tagColor,
             at: NSPoint(x: rowRect.maxX - 10 - tagSize.width, y: rowRect.midY - tagFont.pointSize * 0.75))
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }

    private func size(of text: String, font: NSFont) -> NSSize {
        NSAttributedString(string: text, attributes: [.font: font]).size()
    }
}
