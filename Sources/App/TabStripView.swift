import AppKit

protocol TabStripViewDelegate: AnyObject {
    func tabStripView(_ tabStripView: TabStripView, didSelectTabAt index: Int)
    func tabStripView(_ tabStripView: TabStripView, didCloseTabAt index: Int)
    func tabStripViewDidClickNewTab(_ tabStripView: TabStripView)
}

/// Compact Safari-like tab strip: fixed-height row of TabButtonViews sized to
/// share the available width (down to a minimum, then they just get crowded
/// rather than scrolling -- fine for M1's tab counts), plus a trailing "+"
/// button.
final class TabStripView: NSView {
    weak var delegate: TabStripViewDelegate?

    struct DisplayInfo {
        let title: String
        let favicon: NSImage?
    }

    private var infos: [DisplayInfo] = []
    private var selectedIndex = 0
    private var tabButtons: [TabButtonView] = []

    private let newTabButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        button.imageScaling = .scaleProportionallyDown
        return button
    }()

    private static let minTabWidth: CGFloat = 80
    private static let maxTabWidth: CGFloat = 200
    private static let tabSpacing: CGFloat = 2
    private static let sidePadding: CGFloat = 4
    private static let newTabButtonWidth: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        addSubview(newTabButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func reload(tabs: [DisplayInfo], selectedIndex: Int) {
        infos = tabs
        self.selectedIndex = selectedIndex
        rebuildButtons()
        needsLayout = true
    }

    /// Cheaper than a full reload: use when only a tab's title/loading state
    /// changed, not the tab count or selection.
    func updateTitle(at index: Int, title: String) {
        guard tabButtons.indices.contains(index) else { return }
        tabButtons[index].setTitle(title)
    }

    /// Cheaper than a full reload -- see updateTitle. `nil` reverts to the
    /// generic glyph.
    func updateFavicon(at index: Int, image: NSImage?) {
        guard tabButtons.indices.contains(index) else { return }
        tabButtons[index].setFavicon(image)
    }

    func updateSelection(_ index: Int) {
        selectedIndex = index
        for (i, button) in tabButtons.enumerated() {
            button.isSelected = i == index
        }
    }

    private func rebuildButtons() {
        for button in tabButtons {
            button.removeFromSuperview()
        }
        tabButtons = infos.enumerated().map { index, info in
            let button = TabButtonView(index: index, title: info.title)
            button.setFavicon(info.favicon)
            button.isSelected = index == selectedIndex
            button.onSelect = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didSelectTabAt: index)
            }
            button.onClose = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didCloseTabAt: index)
            }
            addSubview(button)
            return button
        }
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    private func layoutTabs() {
        let available = max(0, bounds.width - Self.sidePadding * 2 - Self.newTabButtonWidth - Self.sidePadding)
        let count = max(tabButtons.count, 1)
        let evenWidth = tabButtons.isEmpty ? available : (available - Self.tabSpacing * CGFloat(count - 1)) / CGFloat(count)
        let width = min(Self.maxTabWidth, max(Self.minTabWidth, evenWidth))

        var x = Self.sidePadding
        for button in tabButtons {
            button.frame = NSRect(x: x, y: 4, width: width, height: max(0, bounds.height - 8))
            x += width + Self.tabSpacing
        }

        newTabButton.frame = NSRect(
            x: bounds.width - Self.newTabButtonWidth - Self.sidePadding,
            y: (bounds.height - 20) / 2,
            width: 20,
            height: 20
        )
    }

    @objc private func newTabTapped() {
        delegate?.tabStripViewDidClickNewTab(self)
    }
}
