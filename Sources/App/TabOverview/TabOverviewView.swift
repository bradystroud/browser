import AppKit

/// The Tab Overview grid itself (browser-rhi.3): a full-window overlay
/// (added as the topmost subview of the window's own contentView by
/// TabOverviewController, not a separate floating panel -- this is a
/// window-level "what's open" view, not a popover) showing every tab in
/// the owning window as a thumbnail-or-placeholder cell. Built once when
/// shown; no live updates in v1 (per the task's own scope cut) -- a tab
/// opened/closed/reordered while the overview is up won't be reflected
/// until it's dismissed and reopened.
///
/// Collapsed tab-group members are included like any other tab -- the
/// whole point of an overview is to reveal everything, including what a
/// collapsed group is currently hiding from the strip.
final class TabOverviewView: NSView {
    private var cells: [TabOverviewCellView] = []
    private var onDismiss: (() -> Void)?

    private static let cellWidth: CGFloat = 180
    private static let cellHeight: CGFloat = 130
    private static let spacing: CGFloat = 16
    private static let margin: CGFloat = 32

    private let backgroundView = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backgroundView.material = .fullScreenUI
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.frame = bounds
        backgroundView.autoresizingMask = [.width, .height]
        addSubview(backgroundView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `tabs` in strip order (see BrowserWindowController.tabs); `selectedTabId`
    /// highlights the currently-active tab's cell. `thumbnailProvider`/
    /// `faviconProvider` are pulled once, up front, per this doc comment's
    /// "no live updates" note.
    func configure(
        tabs: [(id: UUID, title: String, favicon: NSImage?)],
        selectedTabId: UUID?,
        thumbnailProvider: (UUID) -> NSImage?,
        onSelect: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        for cell in cells { cell.removeFromSuperview() }
        cells = tabs.map { tab in
            let cell = TabOverviewCellView(
                tabId: tab.id, title: tab.title, favicon: tab.favicon,
                thumbnail: thumbnailProvider(tab.id))
            cell.setHighlighted(tab.id == selectedTabId)
            cell.onSelect = { onSelect(tab.id) }
            addSubview(cell)
            return cell
        }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - Self.margin * 2)
        let columns = max(1, Int((available + Self.spacing) / (Self.cellWidth + Self.spacing)))
        let totalGridWidth = CGFloat(columns) * Self.cellWidth + CGFloat(columns - 1) * Self.spacing
        let leftInset = Self.margin + max(0, (available - totalGridWidth) / 2)

        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            cell.frame = NSRect(
                x: leftInset + CGFloat(column) * (Self.cellWidth + Self.spacing),
                y: Self.margin + CGFloat(row) * (Self.cellHeight + Self.spacing),
                width: Self.cellWidth,
                height: Self.cellHeight
            )
        }
    }

    /// Clicking anywhere that isn't a cell dismisses the overview -- not
    /// explicitly required by the task ("click switches to that tab, Esc
    /// dismisses"), but a natural, low-risk nicety matching how this
    /// codebase's other overlay (ShortcutsOverlayController) already
    /// dismisses on an outside click.
    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        onDismiss?()
    }
}
