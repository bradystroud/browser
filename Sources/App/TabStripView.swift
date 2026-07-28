import AppKit

protocol TabStripViewDelegate: AnyObject {
    func tabStripView(_ tabStripView: TabStripView, didSelectTabAt index: Int)
    func tabStripView(_ tabStripView: TabStripView, didCloseTabAt index: Int)
    func tabStripViewDidClickNewTab(_ tabStripView: TabStripView)

    /// Tab strip's context menu -- "Pin Tab"/"Unpin Tab" (see TabButtonView).
    func tabStripView(_ tabStripView: TabStripView, didRequestPinToggleAt index: Int)

    /// Tab strip's context menu -- "Close Other Tabs".
    func tabStripView(_ tabStripView: TabStripView, didRequestCloseOthersAt index: Int)

    /// Tab context menu -- "Move to Group > <existing group>".
    func tabStripView(_ tabStripView: TabStripView, didRequestMoveToGroupAt index: Int, groupId: UUID)

    /// Tab context menu -- "Move to Group > New Group…".
    func tabStripView(_ tabStripView: TabStripView, didRequestMoveToNewGroupAt index: Int)

    /// Tab context menu -- "Remove from Group".
    func tabStripView(_ tabStripView: TabStripView, didRequestRemoveFromGroupAt index: Int)

    /// Group header click -- toggle collapsed/expanded.
    func tabStripView(_ tabStripView: TabStripView, didRequestToggleCollapseForGroup groupId: UUID)

    /// Group header context menu -- "Rename".
    func tabStripView(_ tabStripView: TabStripView, didRequestRenameForGroup groupId: UUID)

    /// Group header context menu -- "Change Color".
    func tabStripView(_ tabStripView: TabStripView, didRequestChangeColorForGroup groupId: UUID)

    /// Group header context menu -- "Ungroup All".
    func tabStripView(_ tabStripView: TabStripView, didRequestUngroupAllForGroup groupId: UUID)

    /// Group header context menu -- "Close Group".
    func tabStripView(_ tabStripView: TabStripView, didRequestCloseGroup groupId: UUID)
}

/// Compact Safari-like tab strip: fixed-height row of TabButtonViews (plus
/// TabGroupHeaderViews for tab groups) sized to share the available width
/// (down to a minimum, then they just get crowded rather than scrolling --
/// fine for this app's tab counts), plus a trailing "+" button.
///
/// Rendering order left to right: pinned tabs, then each tab group's header
/// (+ its member tabs if expanded) in group order, then loose (unpinned,
/// ungrouped) tabs -- see BrowserWindowController's ordering invariant on
/// `tabs`, which `infos`/`groups` below always already reflect by the time
/// they reach this view (this view never reorders anything itself, only
/// renders the order it's given).
final class TabStripView: NSView {
    weak var delegate: TabStripViewDelegate?

    struct DisplayInfo {
        let title: String
        let favicon: NSImage?
        let isPinned: Bool
        let groupId: UUID?
        /// The page's `<meta name="theme-color">` value, if any (browser-
        /// rhi.5) -- only ever rendered as a tint when this button is also
        /// the selected one (see TabButtonView.draw(_:)); carried on every
        /// button regardless so switching selection doesn't need a fresh
        /// reload just to pick up the newly-active tab's color.
        let themeColorHex: String?
    }

    struct GroupDisplayInfo {
        let id: UUID
        let name: String
        let colorHex: String
        let isCollapsed: Bool
    }

    /// One visual slot in the strip, in left-to-right render order -- a tab
    /// button or a group header. Built fresh by rebuildButtons every reload;
    /// laid out by walking this single ordered list once, rather than
    /// re-deriving render order from separately-tracked button/header arrays.
    private enum StripItem {
        case tab(TabButtonView)
        case groupHeader(TabGroupHeaderView)
    }

    private var infos: [DisplayInfo] = []
    private var groups: [GroupDisplayInfo] = []
    private var selectedIndex = 0
    private var stripItems: [StripItem] = []

    private let newTabButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        button.imageScaling = .scaleProportionallyDown
        // Glassy, borderless icon button (browser-qpy) -- matches the
        // toolbar's back/forward/reload treatment.
        button.contentTintColor = .secondaryLabelColor
        return button
    }()

    private static let minTabWidth: CGFloat = 80
    private static let maxTabWidth: CGFloat = 200
    /// Pinned tabs render at this fixed, narrow width regardless of strip
    /// width or tab count -- just enough for a centered favicon, no title,
    /// no close button (Safari-style).
    private static let pinnedTabWidth: CGFloat = 36
    /// Group headers render at one of these two fixed widths (not part of
    /// the flexible even-width pool tab buttons share) -- expanded shows the
    /// name, collapsed just a color dot + count badge.
    private static let groupHeaderWidth: CGFloat = 110
    private static let collapsedGroupHeaderWidth: CGFloat = 50
    private static let tabSpacing: CGFloat = 2
    private static let sidePadding: CGFloat = 4
    private static let newTabButtonWidth: CGFloat = 24

    /// Extra space reserved before the first tab, for the traffic-light
    /// buttons that now float over this area once the window's titlebar is
    /// hidden (browser-qpy's liquid-glass restyle) -- set once by
    /// BrowserWindowController, 0 by default so this view still lays out
    /// sensibly if ever reused somewhere without a hidden titlebar.
    var leadingInset: CGFloat = 0 {
        didSet {
            guard oldValue != leadingInset else { return }
            needsLayout = true
        }
    }

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

    func reload(tabs: [DisplayInfo], groups: [GroupDisplayInfo], selectedIndex: Int) {
        infos = tabs
        self.groups = groups
        self.selectedIndex = selectedIndex
        rebuildButtons()
        needsLayout = true
    }

    /// Cheaper than a full reload: use when only a tab's title/loading state
    /// changed, not the tab count, grouping, or selection.
    func updateTitle(at index: Int, title: String) {
        tabButton(forTabIndex: index)?.setTitle(title)
    }

    /// Cheaper than a full reload -- see updateTitle. `nil` reverts to the
    /// generic glyph.
    func updateFavicon(at index: Int, image: NSImage?) {
        tabButton(forTabIndex: index)?.setFavicon(image)
    }

    /// Cheaper than a full reload -- see updateTitle. `nil` clears the tint
    /// (see TabButtonView.draw(_:) -- only ever visible when this button is
    /// also selected, but harmless to set unconditionally).
    func updateThemeColor(at index: Int, hex: String?) {
        tabButton(forTabIndex: index)?.themeColorHex = hex
    }

    func updateSelection(_ index: Int) {
        selectedIndex = index
        for item in stripItems {
            guard case .tab(let button) = item else { continue }
            button.isSelected = button.index == index
        }
    }

    /// ⌘W on a pinned active tab is a no-op (see BrowserWindowController.
    /// closeTab(_:)) -- this gives the user visible feedback that the key
    /// press registered instead of silently doing nothing.
    func shakeTab(at index: Int) {
        tabButton(forTabIndex: index)?.shake()
    }

    /// Looks up a tab button by its real index into BrowserWindowController.
    /// tabs (TabButtonView.index) -- not a position in `stripItems`, which
    /// interleaves group headers and skips collapsed groups' member buttons
    /// entirely, so it no longer lines up 1:1 with tab indices the way the
    /// old flat tabButtons array did before groups existed.
    private func tabButton(forTabIndex index: Int) -> TabButtonView? {
        for item in stripItems {
            if case .tab(let button) = item, button.index == index {
                return button
            }
        }
        return nil
    }

    private func rebuildButtons() {
        for item in stripItems {
            switch item {
            case .tab(let button): button.removeFromSuperview()
            case .groupHeader(let header): header.removeFromSuperview()
            }
        }
        stripItems = []

        let indexed = Array(infos.enumerated())
        let availableGroups = groups.map { (id: $0.id, name: $0.name) }

        func makeButton(_ index: Int, _ info: DisplayInfo) -> TabButtonView {
            let button = TabButtonView(index: index, title: info.title)
            button.setFavicon(info.favicon)
            button.isPinned = info.isPinned
            button.groupId = info.groupId
            button.themeColorHex = info.themeColorHex
            button.availableGroups = availableGroups
            button.isSelected = index == selectedIndex
            button.onSelect = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didSelectTabAt: index)
            }
            button.onClose = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didCloseTabAt: index)
            }
            button.onPinToggle = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestPinToggleAt: index)
            }
            button.onCloseOthers = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestCloseOthersAt: index)
            }
            button.onMoveToGroup = { [weak self] groupId in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestMoveToGroupAt: index, groupId: groupId)
            }
            button.onMoveToNewGroup = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestMoveToNewGroupAt: index)
            }
            button.onRemoveFromGroup = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestRemoveFromGroupAt: index)
            }
            return button
        }

        // Pinned tabs first.
        for (index, info) in indexed where info.isPinned {
            let button = makeButton(index, info)
            addSubview(button)
            stripItems.append(.tab(button))
        }

        // Then each group's section, in order: header, then its member
        // tabs (only if expanded).
        for group in groups {
            let header = TabGroupHeaderView(groupId: group.id, name: group.name, colorHex: group.colorHex)
            header.isCollapsed = group.isCollapsed
            let members = indexed.filter { !$0.element.isPinned && $0.element.groupId == group.id }
            header.memberCount = members.count
            header.onToggleCollapse = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestToggleCollapseForGroup: group.id)
            }
            header.onRename = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestRenameForGroup: group.id)
            }
            header.onChangeColor = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestChangeColorForGroup: group.id)
            }
            header.onUngroupAll = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestUngroupAllForGroup: group.id)
            }
            header.onCloseGroup = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestCloseGroup: group.id)
            }
            addSubview(header)
            stripItems.append(.groupHeader(header))

            guard !group.isCollapsed else { continue }
            for (index, info) in members {
                let button = makeButton(index, info)
                addSubview(button)
                stripItems.append(.tab(button))
            }
        }

        // Then loose (unpinned, ungrouped) tabs.
        for (index, info) in indexed where !info.isPinned && info.groupId == nil {
            let button = makeButton(index, info)
            addSubview(button)
            stripItems.append(.tab(button))
        }
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// Walks `stripItems` once, left to right, in the same render order
    /// rebuildButtons already established. Pinned tabs and group headers get
    /// fixed widths off the top; every other tab button (loose, or a member
    /// of an expanded group) shares whatever width remains, same
    /// even-width-down-to-a-minimum scheme as before groups existed.
    private func layoutTabs() {
        let available = max(0, bounds.width - leadingInset - Self.sidePadding * 2 - Self.newTabButtonWidth - Self.sidePadding)
        let itemCount = stripItems.count
        let totalSpacing = itemCount > 1 ? Self.tabSpacing * CGFloat(itemCount - 1) : 0

        var fixedWidthTotal: CGFloat = 0
        var flexibleTabCount = 0
        for item in stripItems {
            switch item {
            case .tab(let button):
                if button.isPinned {
                    fixedWidthTotal += Self.pinnedTabWidth
                } else {
                    flexibleTabCount += 1
                }
            case .groupHeader(let header):
                fixedWidthTotal += header.isCollapsed ? Self.collapsedGroupHeaderWidth : Self.groupHeaderWidth
            }
        }
        let remainingForFlexible = max(0, available - totalSpacing - fixedWidthTotal)
        let evenFlexibleWidth = flexibleTabCount > 0 ? remainingForFlexible / CGFloat(flexibleTabCount) : 0
        let flexibleWidth = min(Self.maxTabWidth, max(Self.minTabWidth, evenFlexibleWidth))

        var x = Self.sidePadding
        for item in stripItems {
            let width: CGFloat
            let view: NSView
            switch item {
            case .tab(let button):
                width = button.isPinned ? Self.pinnedTabWidth : flexibleWidth
                view = button
            case .groupHeader(let header):
                width = header.isCollapsed ? Self.collapsedGroupHeaderWidth : Self.groupHeaderWidth
                view = header
            }
            view.frame = NSRect(x: x, y: 4, width: width, height: max(0, bounds.height - 8))
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
