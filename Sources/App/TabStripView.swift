import AppKit

protocol TabStripViewDelegate: AnyObject {
    func tabStripView(_ tabStripView: TabStripView, didSelectTabAt index: Int)
    func tabStripView(_ tabStripView: TabStripView, didCloseTabAt index: Int)
    func tabStripViewDidClickNewTab(_ tabStripView: TabStripView)

    /// Tab strip's context menu -- "Pin Tab"/"Unpin Tab" (see TabButtonView).
    func tabStripView(_ tabStripView: TabStripView, didRequestPinToggleAt index: Int)

    /// Tab strip's context menu -- "Close Other Tabs".
    func tabStripView(_ tabStripView: TabStripView, didRequestCloseOthersAt index: Int)

    /// Speaker icon click, or context menu's "Mute Tab"/"Unmute Tab"
    /// (browser-rhi.4, see TabButtonView).
    func tabStripView(_ tabStripView: TabStripView, didRequestMuteToggleAt index: Int)

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

    /// Drag-to-reorder committed (browser-rhi.6). `destinationIndex` is the
    /// tab's *final* position in BrowserWindowController.tabs -- i.e. remove
    /// the tab at `sourceIndex`, then insert it at `destinationIndex` -- not
    /// an insertion point measured against the pre-removal array, which is
    /// ambiguous by one for a rightward move.
    func tabStripView(_ tabStripView: TabStripView, didMoveTabAt sourceIndex: Int, toIndex destinationIndex: Int)
}

/// Hosts every tab pill/group header, in either orientation, with the origin
/// at its *top* left. Item frames are computed top-down in both modes: the
/// vertical sidebar needs that to read in source order, and a horizontal
/// strip's own slots are vertically symmetric within the row (see
/// horizontalSlotFrames), so flipping costs it nothing. It is also what makes
/// the sidebar's scroll view start at the first tab rather than the last --
/// NSScrollView scrolls a flipped document view to its top by default.
private final class TabStripContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Compact Safari-like tab strip in one of two orientations (see
/// TabStripOrientation):
///
/// - horizontal: a fixed-height row of TabButtonViews (plus
///   TabGroupHeaderViews for tab groups) sized to share the available width
///   (down to a minimum, then they just get crowded rather than scrolling --
///   fine for this app's tab counts), plus a trailing "+" button.
/// - vertical: a fixed-width sidebar of full-width rows, pinned tabs as a
///   compact favicon grid at the top, group members indented under their
///   header, scrolling when they overflow, and a "New Tab" row pinned to the
///   bottom edge (Arc's placement -- it must not scroll away).
///
/// Rendering order (left to right, or top to bottom): pinned tabs, then each
/// tab group's header (+ its member tabs if expanded) in group order, then
/// loose (unpinned, ungrouped) tabs -- see BrowserWindowController's ordering
/// invariant on `tabs`, which `infos`/`groups` below always already reflect by
/// the time they reach this view (this view never reorders anything itself,
/// only renders the order it's given).
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
        /// Mirrors Tab.isMuted/isAudible (browser-rhi.4) -- see
        /// TabButtonView.updateIconState() for how these and isLoading
        /// below combine into the icon shown in the shared favicon slot.
        let isMuted: Bool
        let isAudible: Bool
        /// Mirrors Tab.isLoading (browser-7z5).
        let isLoading: Bool
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

        var view: NSView {
            switch self {
            case .tab(let button): return button
            case .groupHeader(let header): return header
            }
        }

        func isTabButton(_ button: TabButtonView) -> Bool {
            if case .tab(let candidate) = self { return candidate === button }
            return false
        }
    }

    /// Which contiguous run of the strip a tab belongs to. The [pinned][group
    /// sections][loose] ordering invariant BrowserWindowController maintains
    /// on `tabs` means each of these is one unbroken run of `stripItems`, and
    /// drag-to-reorder confines a tab to its own run (see sectionRange).
    private enum SectionKey: Equatable {
        case pinned
        case group(UUID)
        case loose
    }

    private var infos: [DisplayInfo] = []
    private var groups: [GroupDisplayInfo] = []
    private var selectedIndex = 0
    private var stripItems: [StripItem] = []

    /// In-flight drag-to-reorder (browser-rhi.6), nil the rest of the time.
    private var drag: DragSession?

    /// `--drag-selftest` runs once per strip, from layout -- see
    /// runDragSelfTestIfRequested.
    private var hasRunDragSelfTest = false

    /// Bumped by every reload. A drop's commit is deferred by the length of
    /// its settle animation, so this is what tells that deferred commit its
    /// captured tab indices went stale underneath it (the strip was rebuilt
    /// from a model that moved on its own in the meantime) and it must not
    /// apply a move computed against the old order.
    private var reloadGeneration = 0

    private struct DragSession {
        let button: TabButtonView
        /// Position in `stripItems` the dragged pill currently occupies --
        /// moves as the drag swaps it past its neighbours.
        var itemIndex: Int
        /// The `stripItems` range the pill may travel within: its own section
        /// (see SectionKey), so a drag can never reorder a tab across the
        /// pinned/grouped/loose boundaries the ordering invariant depends on,
        /// nor past a group header.
        let range: ClosedRange<Int>
        /// Mouse location in this view's coordinates at mouse-down, and the
        /// pill's frame then -- the drag positions the pill from these plus
        /// the live delta, never from the raw pointer, so the pill keeps the
        /// same grab point under the cursor throughout.
        let startPoint: NSPoint
        let startFrame: NSRect
        /// `stripItems` exactly as it was at mouse-down, restored verbatim if
        /// the drag is cancelled with Escape.
        let originalItems: [StripItem]
        /// Still false until the pointer has travelled far enough to be a
        /// drag rather than a click with a shaky hand -- nothing moves, and
        /// nothing is committed, while this is false.
        var didMove = false
        /// The one local event monitor the whole drag runs off, installed at
        /// mouse-down and removed however the drag ends -- see
        /// tabButton(_:didBeginDragWith:).
        var eventMonitor: Any?
    }

    /// How far the pointer must travel along the strip's own axis before a
    /// mouse-down is treated as a drag at all (see continueDrag -- the
    /// sidebar's pinned grid measures plain distance instead).
    private static let dragMovementThreshold: CGFloat = 4
    /// Neighbours sliding aside as the dragged pill passes them.
    private static let reflowAnimationDuration: TimeInterval = 0.14
    /// The dropped pill settling into its slot.
    private static let dropAnimationDuration: TimeInterval = 0.12

    private let newTabButton: NSButton = {
        let button = NSButton()
        button.title = "New Tab"
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        button.applyChromeAppearance(.glass)
        button.toolTip = "New Tab"
        return button
    }()
    /// The item area itself: a direct subview of `self` in horizontal mode,
    /// and the sidebar scroll view's document view in vertical mode. Every
    /// tab pill/group header lives inside it (via glassContentHost below), so
    /// swapping which of the two it is parented to is the whole of the
    /// "sidebar scrolls, strip doesn't" difference -- nothing downstream of
    /// it, drag included, has to know which mode it is in.
    private let stripContentView = TabStripContentView()

    /// Vertical mode only, and only installed while it is (see
    /// configureHierarchyForOrientation) -- a sidebar that silently hides
    /// tabs past the window's height would be worse than no sidebar.
    private let scrollView = NSScrollView()

    /// macOS 26+ only: hosts every tab/group-header's own NSGlassEffectView
    /// so they batch-render and merge together when close, matching how
    /// Safari's own adjacent tab pills blend into each other rather than
    /// reading as separate frosted rectangles (see
    /// NSGlassEffectContainerView's own header doc comment, and browser-qpy-
    /// notes.md for the spacing value's rationale). `nil` pre-26.
    private var glassContainer: NSView?
    /// Where rebuildButtons() actually adds each tab/group-header subview --
    /// the glass container's contentView on macOS 26+, stripContentView
    /// otherwise. Set once, read (never reassigned after) by rebuildButtons
    /// on every reload; every slot frame this view computes is in *this*
    /// view's coordinates, which is why the drag converts pointer locations
    /// through it rather than through `self`.
    private lazy var glassContentHost: NSView = {
        guard #available(macOS 26.0, *) else { return stripContentView }
        let container = NSGlassEffectContainerView(frame: stripContentView.bounds)
        container.autoresizingMask = [.width, .height]
        // Nonzero so adjacent pills within this distance visually merge
        // (the default, zero, only batches rendering -- see the class's own
        // doc comment) -- a starting guess, not verified against a real
        // render; see browser-qpy-notes.md's Deviations for why this is
        // flagged for Brady to tune once he can actually see it.
        container.spacing = 4
        // Flipped for the same reason stripContentView is -- this, not that,
        // is what the item frames are measured in on macOS 26+.
        let content = TabStripContentView(frame: stripContentView.bounds)
        content.autoresizingMask = [.width, .height]
        container.contentView = content
        stripContentView.addSubview(container)
        glassContainer = container
        return content
    }()

    /// Horizontal row or vertical sidebar. Set by BrowserWindowController,
    /// which owns the surrounding geometry this only describes the inside of
    /// -- changing it here relays out the strip's own contents, but the frame
    /// it is given (and the web content area it was shrunk out of) is the
    /// controller's to change in the same pass.
    var orientation: TabStripOrientation = .horizontal {
        didSet {
            guard oldValue != orientation else { return }
            applyOrientation()
        }
    }

    private var isVertical: Bool { orientation == .vertical }

    private static let minTabWidth: CGFloat = 80
    /// Pinned tabs render at this fixed, narrow width regardless of strip
    /// width or tab count -- just enough for a centered favicon, no title,
    /// no close button (Safari-style).
    private static let pinnedTabWidth: CGFloat = 36
    /// Group headers render at one of these two fixed widths (not part of
    /// the flexible even-width pool tab buttons share) -- expanded shows the
    /// name, collapsed just a color dot + count badge.
    private static let groupHeaderWidth: CGFloat = 110
    private static let collapsedGroupHeaderWidth: CGFloat = 50
    /// Gap between adjacent pills. Has to clear the pill's own rounded ends
    /// *and* the soft edge NSGlassEffectView renders slightly beyond its
    /// bounds -- at the original 2pt the two together read as tabs touching,
    /// and in places overlapping, rather than as a deliberate gap.
    private static let tabSpacing: CGFloat = 7
    private static let sidePadding: CGFloat = 4

    // MARK: Vertical (sidebar) metrics

    /// The sidebar's own width, published because BrowserWindowController has
    /// to shrink the web content area by exactly this much -- one constant,
    /// read by both sides, rather than the same number written twice.
    /// Between Safari's ~220 and Arc's ~240: wide enough that a real page
    /// title survives truncation, narrow enough not to eat the content area.
    static let sidebarWidth: CGFloat = 240
    private static let verticalRowHeight: CGFloat = 32
    private static let verticalGroupHeaderHeight: CGFloat = 26
    /// Tighter than the horizontal strip's own tabSpacing: rows share their
    /// full width, so they read as a list at a spacing that would look
    /// cramped between side-by-side pills.
    private static let verticalRowSpacing: CGFloat = 4
    /// Between the pinned grid and the first row below it, and above each
    /// group header -- what makes the sections read as sections.
    private static let verticalSectionSpacing: CGFloat = 10
    private static let verticalPadding: CGFloat = 10
    /// Group members sit indented under their header, as they do in Safari's
    /// own sidebar -- the horizontal strip has no room for this and relies on
    /// adjacency alone, which a vertical list makes ambiguous.
    private static let verticalGroupIndent: CGFloat = 14
    /// Pinned tabs render as a compact favicon grid at the top of the
    /// sidebar (Safari's treatment) rather than as full-width rows: a pinned
    /// tab has no title to show, so a full-width row for each would be a
    /// column of mostly-empty pills.
    private static let verticalPinnedTileSize: CGFloat = 34
    private static let verticalPinnedSpacing: CGFloat = 6
    /// The "New Tab" row's band at the sidebar's bottom edge. Outside the
    /// scroll view on purpose -- it is the one control that must stay
    /// reachable however far the tab list has been scrolled.
    private static let verticalNewTabRowHeight: CGFloat = 42

    /// Extra space reserved before the first tab, for e.g. traffic-light
    /// buttons floating over this area. Unused (stays at its default 0)
    /// since browser-0y1 flipped the chrome order -- the toolbar/omnibox
    /// row is on top now, so the traffic lights float over *that* row's
    /// leading edge instead (see BrowserWindowController.
    /// trafficLightReservedWidth). Kept as a general capability rather than
    /// removed, in case a future layout puts the tab strip back on top.
    var leadingInset: CGFloat = 0 {
        didSet {
            guard oldValue != leadingInset else { return }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stripContentView.frame = bounds
        stripContentView.autoresizingMask = [.width, .height]
        addSubview(stripContentView)
        // Force the glass container to be created (and added) now, before
        // newTabButton below, so the button always renders above it.
        _ = glassContentHost
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        // Horizontal (the initial orientation) shows no "+" -- see
        // configureHierarchyForOrientation.
        newTabButton.isHidden = true
        addSubview(newTabButton)
        configureScrollView()
    }

    private func configureScrollView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        // The clip view must not paint either, or it draws an opaque slab
        // over the sidebar's own glass material.
        scrollView.contentView.drawsBackground = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func reload(tabs: [DisplayInfo], groups: [GroupDisplayInfo], selectedIndex: Int) {
        // Every button a live drag is holding on to is about to be thrown
        // away, so abandon the drag outright rather than let it keep moving
        // detached views around. No restore of the pre-drag order is needed
        // (or wanted): the incoming order is the model's, which is now the
        // only truth about where these tabs go.
        abandonDrag()
        reloadGeneration &+= 1
        infos = tabs
        self.groups = groups
        self.selectedIndex = selectedIndex
        rebuildButtons()
        needsLayout = true
        scrollSelectionIntoView()
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
        // A theme color arrives well after the reload that created the
        // button (it comes out of the page's own DOM), and changes nothing
        // about layout -- so without this the contrast report would only
        // ever describe the untinted state it was built in.
        reportSelectionContrastIfRequested()
    }

    /// Cheaper than a full reload -- see updateTitle. Called whenever
    /// Tab.isMuted/isAudible change (browser-rhi.4), both of which can
    /// happen far more often than a full tab-strip reload is warranted for
    /// (isAudible in particular, on TabAudioCoordinator's poll interval).
    func updateAudioState(at index: Int, isMuted: Bool, isAudible: Bool) {
        guard let button = tabButton(forTabIndex: index) else { return }
        button.isMuted = isMuted
        button.isAudible = isAudible
    }

    /// Cheaper than a full reload -- see updateTitle. Called on every
    /// Tab.isLoading change (browser-7z5), i.e. the start/end of every
    /// navigation for this tab.
    func updateLoadingState(at index: Int, isLoading: Bool) {
        tabButton(forTabIndex: index)?.isLoading = isLoading
    }

    func updateSelection(_ index: Int) {
        selectedIndex = index
        for item in stripItems {
            guard case .tab(let button) = item else { continue }
            button.isSelected = button.index == index
        }
        scrollSelectionIntoView()
        reportSelectionContrastIfRequested()
    }

    /// Brings the selected row back on screen when the sidebar has scrolled
    /// past it. Without this, ⌘1-9 and ⌘⌥→ can activate a tab that stays out
    /// of sight -- the strip would be showing a selection nobody can see, and
    /// the horizontal row has no equivalent failure because it never scrolls.
    /// A no-op in horizontal mode, and whenever the row is already visible.
    private func scrollSelectionIntoView() {
        guard isVertical, scrollView.superview === self,
              let button = tabButton(forTabIndex: selectedIndex) else { return }
        // Deferred: a selection change usually arrives with a reload, whose
        // layout (and therefore this row's real frame) has not run yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVertical, button.superview != nil else { return }
            let frame = button.convert(button.bounds, to: self.stripContentView)
            // Padded by a whole row's worth, so a row scrolled to the very
            // bottom does not end up flush against the New Tab band below it.
            self.stripContentView.scrollToVisible(frame.insetBy(dx: 0, dy: -Self.verticalRowHeight / 2))
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
            button.isMuted = info.isMuted
            button.isAudible = info.isAudible
            button.isLoading = info.isLoading
            button.availableGroups = availableGroups
            button.isVerticalLayout = isVertical
            button.isSelected = index == selectedIndex
            button.dragDelegate = self
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
            button.onMuteToggle = { [weak self] in
                guard let self else { return }
                self.delegate?.tabStripView(self, didRequestMuteToggleAt: index)
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
            glassContentHost.addSubview(button)
            stripItems.append(.tab(button))
        }

        // Then each group's section, in order: header, then its member
        // tabs (only if expanded).
        for group in groups {
            let header = TabGroupHeaderView(groupId: group.id, name: group.name, colorHex: group.colorHex)
            header.isCollapsed = group.isCollapsed
            header.isVerticalLayout = isVertical
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
            glassContentHost.addSubview(header)
            stripItems.append(.groupHeader(header))

            guard !group.isCollapsed else { continue }
            for (index, info) in members {
                let button = makeButton(index, info)
                glassContentHost.addSubview(button)
                stripItems.append(.tab(button))
            }
        }

        // Then loose (unpinned, ungrouped) tabs.
        for (index, info) in indexed where !info.isPinned && info.groupId == nil {
            let button = makeButton(index, info)
            glassContentHost.addSubview(button)
            stripItems.append(.tab(button))
        }
    }

    /// Rebuilds whatever differs between the two orientations and nothing
    /// else -- the buttons themselves are reused, so toggling mid-session
    /// keeps every tab's live state (selection, audio, loading spinner)
    /// rather than round-tripping through a reload.
    private func applyOrientation() {
        for item in stripItems {
            switch item {
            case .tab(let button): button.isVerticalLayout = isVertical
            case .groupHeader(let header): header.isVerticalLayout = isVertical
            }
        }
        configureHierarchyForOrientation()
        needsLayout = true
    }

    private func configureHierarchyForOrientation() {
        // The horizontal strip has no "+" of its own: BrowserWindowController
        // keeps one in the toolbar row, because the strip itself is hidden
        // whenever a window has a single tab and "+" must stay reachable.
        newTabButton.isHidden = !isVertical
        if isVertical {
            guard scrollView.superview !== self else { return }
            stripContentView.removeFromSuperview()
            stripContentView.autoresizingMask = [.width]
            scrollView.documentView = stripContentView
            addSubview(scrollView, positioned: .below, relativeTo: newTabButton)
        } else {
            guard stripContentView.superview !== self else { return }
            scrollView.documentView = nil
            scrollView.removeFromSuperview()
            stripContentView.autoresizingMask = [.width, .height]
            stripContentView.frame = bounds
            addSubview(stripContentView, positioned: .below, relativeTo: newTabButton)
        }
    }

    override func layout() {
        super.layout()
        if isVertical {
            layoutVerticalContainers()
        } else {
            setFrameIfNeeded(stripContentView, to: bounds)
        }
        layoutTabs()
    }

    /// Sizes the sidebar's scroll view, its document view (tall enough for
    /// every row, but never shorter than the clip view -- a short document in
    /// a flipped view would still be top-anchored, but sizing it to the clip
    /// view keeps the scroller from appearing for a single pixel of rounding)
    /// and the bottom "New Tab" row.
    private func layoutVerticalContainers() {
        let rowBand = Self.verticalNewTabRowHeight
        setFrameIfNeeded(scrollView, to: NSRect(
            x: 0, y: rowBand, width: bounds.width, height: max(0, bounds.height - rowBand)
        ))
        setFrameIfNeeded(stripContentView, to: NSRect(
            x: 0, y: 0, width: bounds.width,
            height: max(scrollView.contentSize.height, verticalContentHeight())
        ))
        let inset = Self.verticalPadding
        newTabButton.frame = NSRect(
            x: inset, y: (rowBand - Self.verticalRowHeight) / 2,
            width: max(0, bounds.width - inset * 2), height: Self.verticalRowHeight
        )
    }

    /// Assigning a frame inside `layout()` can re-enter it (an NSScrollView
    /// retiles, which lays this view out again); skipping the no-op case is
    /// what stops that from looping.
    private func setFrameIfNeeded(_ view: NSView, to frame: NSRect) {
        guard view.frame != frame else { return }
        view.frame = frame
    }

    private func layoutTabs() {
        let frames = slotFrames()
        for (position, item) in stripItems.enumerated() {
            let view = item.view
            if let session = drag, session.didMove, view === session.button {
                // The dragged pill belongs to the cursor, not to the layout,
                // for as long as the drag lasts. Horizontally it still takes
                // the slot's vertical geometry, which a window resize can
                // genuinely change mid-drag; vertically the sidebar's width
                // is fixed, so only the size is worth re-taking and the pill
                // keeps both of its coordinates (a pinned tab drags on both
                // axes there -- see the pinned grid in verticalSlotFrames).
                view.frame = NSRect(
                    x: view.frame.minX,
                    y: isVertical ? view.frame.minY : frames[position].minY,
                    width: frames[position].width, height: frames[position].height
                )
            } else {
                view.frame = frames[position]
            }
        }

        if case .tab(let firstButton)? = stripItems.first {
            TabDragDiagnostics.probeHitTestingOnce(button: firstButton)
        }
        runDragSelfTestIfRequested()
        reportSelectionContrastIfRequested()
    }

    /// Cached because it is read from `layout()`, which runs often.
    private static let isContrastReportRequested = CommandLine.arguments.contains("--tab-contrast-report")

    /// `--tab-contrast-report`: prints the selected pill's measured colors
    /// and contrast ratios (browser-qpy.1) every time the strip lays out,
    /// so switching tabs walks through every theme color in the window and
    /// the numbers for each land in the log.
    ///
    /// This exists because "the selected tab is hard to see" cannot be
    /// settled by reading the code -- but it also cannot be settled by a
    /// screenshot alone, which shows *a* result without saying how close to
    /// the edge it was. The screenshots say whether it looks right; this
    /// says by how much, and would keep saying so if a future change to the
    /// chrome tint quietly ate the margin.
    private func reportSelectionContrastIfRequested() {
        guard Self.isContrastReportRequested else { return }
        for item in stripItems {
            guard case .tab(let button) = item, button.index == selectedIndex else { continue }
            NSLog("[tab-contrast] %@", button.selectionContrastReport)
        }
    }

    /// `--drag-selftest`: drives a whole press-drag-release through the same
    /// entry points AppKit calls, using fabricated events, and lets the
    /// diagnostics file record what came out the far end.
    ///
    /// This is emphatically *not* a substitute for a real drag -- it cannot
    /// prove AppKit delivers those events to this view in the first place,
    /// which is precisely what was broken. What it does prove is everything
    /// downstream of delivery: the threshold, the section clamp, the
    /// neighbour swaps, the index arithmetic and the model move. None of that
    /// was reachable by any other non-interactive means, and all of it
    /// previously shipped on desk-checking alone.
    ///
    /// It runs in both orientations, along whichever axis that orientation
    /// reorders on -- the sidebar's reorder path is a different one (nearest
    /// slot centre rather than neighbour swaps, see moveVertically), so a
    /// self-test that only ever travelled along x would leave exactly the
    /// newer of the two untested.
    private func runDragSelfTestIfRequested() {
        guard !hasRunDragSelfTest, TabDragDiagnostics.isSelfTestRequested,
              let window, stripItems.count >= 3,
              let button = selfTestSubject(), button.bounds.width > 0 else { return }
        hasRunDragSelfTest = true

        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            let inWindow = glassContentHost.convert(point, to: nil)
            return NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }

        let start = NSPoint(x: button.frame.midX, y: button.frame.midY)
        // Far enough to clear two whole slots, so the drag has to pass two
        // neighbours and the committed index can't accidentally match the
        // source. +8 so the pill's centre lands clearly past the second
        // slot's midpoint rather than exactly on it (an exact tie doesn't
        // move it).
        let end: NSPoint = isVertical
            ? NSPoint(x: start.x, y: start.y + (button.frame.height + Self.verticalRowSpacing) * 2 + 8)
            : NSPoint(x: start.x + (button.frame.width + Self.tabSpacing) * 2 + 8, y: start.y)
        TabDragDiagnostics.record("selfTestStart", [
            "tabIndex": button.index, "orientation": orientation.rawValue,
            "startX": Double(start.x), "startY": Double(start.y),
            "endX": Double(end.x), "endY": Double(end.y),
            "stripItemCount": stripItems.count
        ])
        guard let down = event(.leftMouseDown, at: start) else { return }
        tabButton(button, didBeginDragWith: down)
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            let point = NSPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            guard let dragged = event(.leftMouseDragged, at: point) else { continue }
            tabButton(button, didDragWith: dragged)
        }
        guard let up = event(.leftMouseUp, at: end) else { return }
        tabButton(button, didEndDragWith: up)
    }

    /// The tab the self-test drags: the first one with at least two other
    /// slots in its own section, so a two-slot journey stays inside the
    /// section clamp and actually lands somewhere new.
    ///
    /// Pinned tabs are excluded in the sidebar, and only there: they render
    /// as a grid whose whole run is one 34pt-tall row, so a downward drag
    /// would be clamped to its own starting row and the test would prove
    /// nothing. They are a perfectly good subject in the horizontal strip,
    /// where their section runs along the axis being tested.
    private func selfTestSubject() -> TabButtonView? {
        for (position, item) in stripItems.enumerated() {
            guard case .tab(let button) = item else { continue }
            if isVertical, button.isPinned { continue }
            guard sectionRange(around: position).count >= 3 else { continue }
            return button
        }
        return nil
    }


    /// The frame each entry of `stripItems` should occupy, in the same render
    /// order rebuildButtons established, for whichever orientation is current
    /// -- everything else in this view works off these rects and never asks
    /// which way the strip runs.
    ///
    /// Pure geometry, deliberately: drag-to-reorder needs to know where slots
    /// *are* without moving anything into them (to decide when the dragged
    /// pill has crossed a neighbour) and needs to animate views into them
    /// rather than assign frames outright, neither of which the old
    /// compute-and-assign-in-one-pass layout could express. It also means
    /// every slot within one section is identical in size by construction, in
    /// both orientations, which is what lets a drag compare against fixed
    /// slot geometry that stays valid as items are reordered underneath it.
    private func slotFrames() -> [NSRect] {
        isVertical ? verticalSlotFrames() : horizontalSlotFrames()
    }

    /// How tall the sidebar's document view has to be for every row to fit.
    /// Derived from the same pass that positions them, so the two can't
    /// disagree about where the last row ends.
    private func verticalContentHeight() -> CGFloat {
        let frames = verticalSlotFrames()
        guard let bottom = frames.map(\.maxY).max() else { return 0 }
        return bottom + Self.verticalPadding
    }

    /// Vertical (sidebar) layout, top-down in stripContentView's flipped
    /// coordinates. Three bands in the order rebuildButtons already
    /// established: the pinned favicon grid, then group headers with their
    /// members indented beneath them, then loose tabs.
    ///
    /// Same "every slot within one section is identical by construction"
    /// property the horizontal pass has, and for the same reason -- the drag
    /// compares against fixed slot geometry that must stay valid while items
    /// are reordered underneath it.
    private func verticalSlotFrames() -> [NSRect] {
        let inset = Self.verticalPadding
        let contentWidth = max(0, bounds.width - inset * 2)
        var frames: [NSRect] = []
        frames.reserveCapacity(stripItems.count)
        var y = Self.verticalPadding
        var position = 0

        // Pinned tabs: a grid of favicon tiles. They are always the strip's
        // leading run (BrowserWindowController's ordering invariant), so this
        // consumes them up front rather than branching per item below.
        var pinnedCount = 0
        while position + pinnedCount < stripItems.count,
              case .tab(let button) = stripItems[position + pinnedCount], button.isPinned {
            pinnedCount += 1
        }
        if pinnedCount > 0 {
            let tile = Self.verticalPinnedTileSize
            let gap = Self.verticalPinnedSpacing
            let perRow = max(1, Int((contentWidth + gap) / (tile + gap)))
            for offset in 0..<pinnedCount {
                let row = offset / perRow
                let column = offset % perRow
                frames.append(NSRect(
                    x: inset + CGFloat(column) * (tile + gap),
                    y: y + CGFloat(row) * (tile + gap),
                    width: tile, height: tile
                ))
            }
            let rows = (pinnedCount + perRow - 1) / perRow
            y += CGFloat(rows) * tile + CGFloat(rows - 1) * gap + Self.verticalSectionSpacing
            position += pinnedCount
        }

        while position < stripItems.count {
            switch stripItems[position] {
            case .groupHeader:
                // A group header opens a section; give it air above unless it
                // is the very first thing in the sidebar.
                if position > 0 {
                    y += Self.verticalSectionSpacing - Self.verticalRowSpacing
                }
                frames.append(NSRect(x: inset, y: y, width: contentWidth, height: Self.verticalGroupHeaderHeight))
                y += Self.verticalGroupHeaderHeight + Self.verticalRowSpacing
            case .tab(let button):
                let indent = button.groupId == nil ? 0 : Self.verticalGroupIndent
                frames.append(NSRect(
                    x: inset + indent, y: y,
                    width: max(0, contentWidth - indent), height: Self.verticalRowHeight
                ))
                y += Self.verticalRowHeight + Self.verticalRowSpacing
            }
            position += 1
        }
        return frames
    }

    /// Horizontal layout, left to right. Pinned tabs and group headers get
    /// fixed widths off the top; every other tab button (loose, or a member
    /// of an expanded group) shares whatever width remains, same
    /// even-width-down-to-a-minimum scheme as before groups existed.
    private func horizontalSlotFrames() -> [NSRect] {
        let available = max(0, bounds.width - leadingInset - Self.sidePadding * 2)
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
        // No upper bound: unpinned tabs stretch to fill the whole strip, so two
        // tabs take half the bar each, Safari-style. Only the lower bound
        // survives -- past minTabWidth the tabs stop shrinking and the strip
        // overflows instead, which is what keeps a tab legible once there are
        // enough of them.
        let flexibleWidth = max(Self.minTabWidth, evenFlexibleWidth)

        var frames: [NSRect] = []
        frames.reserveCapacity(itemCount)
        var x = leadingInset + Self.sidePadding
        for item in stripItems {
            let width: CGFloat
            switch item {
            case .tab(let button):
                width = button.isPinned ? Self.pinnedTabWidth : flexibleWidth
            case .groupHeader(let header):
                width = header.isCollapsed ? Self.collapsedGroupHeaderWidth : Self.groupHeaderWidth
            }
            frames.append(NSRect(x: x, y: 4, width: width, height: max(0, bounds.height - 8)))
            x += width + Self.tabSpacing
        }
        return frames
    }

    /// Moves every item into its slot, optionally sliding rather than
    /// snapping. `skipping` is how the dragged pill is left under the cursor
    /// while its neighbours reflow around it.
    private func applySlotFrames(animated: Bool, skipping skipped: NSView? = nil) {
        let frames = slotFrames()
        func assign(_ context: NSAnimationContext?) {
            for (position, item) in stripItems.enumerated() {
                let view = item.view
                guard view !== skipped else { continue }
                if context != nil {
                    view.animator().frame = frames[position]
                } else {
                    view.frame = frames[position]
                }
            }
        }
        guard animated else {
            assign(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reflowAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            assign(context)
        }
    }

    @objc private func newTabTapped() {
        delegate?.tabStripViewDidClickNewTab(self)
    }
}

// MARK: - Drag to reorder (browser-rhi.6)

extension TabStripView: TabButtonDragDelegate {
    /// Takes over the rest of the mouse sequence a tab button just started.
    ///
    /// Everything after this mouse-down is tracked through one local event
    /// monitor rather than the pressed button's own mouseDragged/mouseUp, for
    /// two reasons: the drag raises the pill above its siblings (which
    /// reshuffles the view hierarchy the button is being routed through mid-
    /// sequence), and Escape-to-cancel needs key events that can't reach a
    /// view through the responder chain while the mouse is down anyway. One
    /// monitor covers all three event kinds and can't get out of step with
    /// itself. Deliberately *not* a nested nextEvent tracking loop: that would
    /// block the main run loop for the length of the drag, and CEF's message
    /// pump (BRWMessagePump) drives the whole engine off that same run loop.
    func tabButton(_ button: TabButtonView, didBeginDragWith event: NSEvent) {
        // A Control-click is a context-menu gesture, and the menu it opens
        // runs its own event loop that a local monitor doesn't see -- the
        // drag would never be told the mouse came back up, and its monitor
        // would outlive it, swallowing every later Escape in the app.
        guard !event.modifierFlags.contains(.control) else {
            TabDragDiagnostics.record("beginDragRefused", ["reason": "control-click", "tabIndex": button.index])
            return
        }
        // Any session still standing here never saw its mouse-up; unwind it
        // rather than refuse to start (which would wedge dragging for good).
        endDrag(commit: false)
        guard let itemIndex = stripItems.firstIndex(where: { $0.isTabButton(button) }) else {
            TabDragDiagnostics.record("beginDragRefused", [
                "reason": "button-not-in-stripItems", "tabIndex": button.index, "stripItemCount": stripItems.count
            ])
            return
        }
        let range = sectionRange(around: itemIndex)
        // A section of one has nowhere to go; don't arm a drag (or a monitor)
        // that could only ever be a no-op.
        guard range.count > 1 else {
            TabDragDiagnostics.record("beginDragRefused", [
                "reason": "section-of-one", "tabIndex": button.index, "itemIndex": itemIndex,
                "section": String(describing: sectionKey(for: button))
            ])
            return
        }

        var session = DragSession(
            button: button,
            itemIndex: itemIndex,
            range: range,
            startPoint: glassContentHost.convert(event.locationInWindow, from: nil),
            startFrame: button.frame,
            originalItems: stripItems
        )
        session.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self, let button = self.drag?.button else { return event }
            switch event.type {
            case .leftMouseDragged:
                self.continueDrag(button, with: event, source: "monitor")
                return event
            case .leftMouseUp:
                self.endDrag(commit: true, source: "monitor")
                return event
            case .keyDown where event.keyCode == 53:
                self.endDrag(commit: false, source: "escape")
                return nil
            default:
                return event
            }
        }
        drag = session
        TabDragDiagnostics.record("beginDragArmed", [
            "tabIndex": button.index,
            "itemIndex": itemIndex,
            "rangeLower": range.lowerBound,
            "rangeUpper": range.upperBound,
            "section": String(describing: sectionKey(for: button)),
            "startFrame": TabDragDiagnostics.describe(button.frame),
            "monitorInstalled": session.eventMonitor != nil
        ])
        TabDragDiagnostics.probeHitTesting(button: button)
    }

    /// Also reachable from the pressed button's own `mouseDragged` -- both
    /// paths are live on purpose (see TabButtonDragDelegate). Idempotent: the
    /// pill's position is recomputed from the drag's start frame plus the
    /// live delta rather than accumulated, and the neighbour swaps below are
    /// conditional on midpoints already crossed, so handling the same event
    /// twice lands on exactly the same state as handling it once.
    func tabButton(_ button: TabButtonView, didDragWith event: NSEvent) {
        continueDrag(button, with: event, source: "view")
    }

    func tabButton(_ button: TabButtonView, didEndDragWith event: NSEvent) {
        endDrag(commit: true, source: "view")
    }

    private func continueDrag(_ button: TabButtonView, with event: NSEvent, source: String) {
        guard let session = drag, session.button === button else { return }
        let point = glassContentHost.convert(event.locationInWindow, from: nil)
        let delta = NSSize(width: point.x - session.startPoint.x, height: point.y - session.startPoint.y)
        // Vertical rows travel on y, but a pinned tile in the sidebar's grid
        // travels on both axes, so the threshold there is plain distance
        // rather than either single component.
        let travelled = isVertical ? hypot(delta.width, delta.height) : abs(delta.width)
        if !session.didMove {
            guard travelled >= Self.dragMovementThreshold else {
                TabDragDiagnostics.record("dragBelowThreshold", [
                    "source": source, "tabIndex": button.index,
                    "travelled": Double(travelled), "threshold": Double(Self.dragMovementThreshold)
                ])
                return
            }
            drag?.didMove = true
            TabDragDiagnostics.record("dragThresholdCrossed", [
                "source": source, "tabIndex": button.index, "travelled": Double(travelled)
            ])
            // Above its neighbours for the rest of the drag, so the pill it
            // slides over never renders on top of the one being dragged.
            glassContentHost.addSubview(button, positioned: .above, relativeTo: nil)
        }

        // Slot geometry is identical for every item in one section (see
        // slotFrames), so `frames` stays valid across the reorder below and
        // never needs recomputing mid-move.
        let frames = slotFrames()
        let itemIndex = isVertical
            ? moveVertically(button, session: session, delta: delta, frames: frames)
            : moveHorizontally(button, session: session, deltaX: delta.width, frames: frames)

        guard itemIndex != session.itemIndex else { return }
        drag?.itemIndex = itemIndex
        TabDragDiagnostics.record("dragReflow", [
            "source": source, "tabIndex": button.index,
            "fromItemIndex": session.itemIndex, "toItemIndex": itemIndex
        ])
        applySlotFrames(animated: true, skipping: button)
    }

    /// Positions the pill along the row and swaps it past whichever
    /// neighbours its centre has crossed, returning its new position in
    /// `stripItems`.
    private func moveHorizontally(
        _ button: TabButtonView, session: DragSession, deltaX: CGFloat, frames: [NSRect]
    ) -> Int {
        let width = button.frame.width
        let lowerLimit = frames[session.range.lowerBound].minX
        let upperLimit = max(lowerLimit, frames[session.range.upperBound].maxX - width)
        let x = min(max(session.startFrame.minX + deltaX, lowerLimit), upperLimit)
        button.frame.origin.x = x

        let center = x + width / 2
        var itemIndex = session.itemIndex
        while itemIndex < session.range.upperBound, center > frames[itemIndex + 1].midX {
            stripItems.swapAt(itemIndex, itemIndex + 1)
            itemIndex += 1
        }
        while itemIndex > session.range.lowerBound, center < frames[itemIndex - 1].midX {
            stripItems.swapAt(itemIndex, itemIndex - 1)
            itemIndex -= 1
        }
        return itemIndex
    }

    /// The sidebar's equivalent, returning the pill's new position in
    /// `stripItems`.
    ///
    /// Targets the *nearest* slot centre rather than swapping past crossed
    /// neighbours the way the row does, because one of the sidebar's sections
    /// is two-dimensional: pinned tabs render as a grid, where "the pill has
    /// crossed its neighbour" has no single axis to be true along. Nearest
    /// centre reduces to exactly the same behaviour for the one-dimensional
    /// column of loose/grouped rows.
    private func moveVertically(
        _ button: TabButtonView, session: DragSession, delta: NSSize, frames: [NSRect]
    ) -> Int {
        // Confine the pill to the bounding box of its own section, so it can
        // never be dragged over a neighbouring band it may not join.
        let sectionFrames = session.range.map { frames[$0] }
        let section = sectionFrames.dropFirst().reduce(sectionFrames[0]) { $0.union($1) }
        let size = button.frame.size
        let origin = NSPoint(
            x: min(max(session.startFrame.minX + delta.width, section.minX), max(section.minX, section.maxX - size.width)),
            y: min(max(session.startFrame.minY + delta.height, section.minY), max(section.minY, section.maxY - size.height))
        )
        button.frame.origin = origin

        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        var target = session.itemIndex
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for position in session.range {
            let slot = frames[position]
            let distance = hypot(slot.midX - center.x, slot.midY - center.y)
            if distance < bestDistance {
                bestDistance = distance
                target = position
            }
        }
        guard target != session.itemIndex else { return session.itemIndex }
        let item = stripItems.remove(at: session.itemIndex)
        stripItems.insert(item, at: target)
        return target
    }

    /// The contiguous run of `stripItems` holding every tab in the same
    /// section as the one at `itemIndex` -- see SectionKey. Group headers
    /// never match, which is what keeps a group's members from being dragged
    /// out past their own header.
    private func sectionRange(around itemIndex: Int) -> ClosedRange<Int> {
        guard case .tab(let button) = stripItems[itemIndex] else { return itemIndex...itemIndex }
        let key = sectionKey(for: button)
        var lower = itemIndex
        while lower > 0, case .tab(let candidate) = stripItems[lower - 1], sectionKey(for: candidate) == key {
            lower -= 1
        }
        var upper = itemIndex
        while upper < stripItems.count - 1, case .tab(let candidate) = stripItems[upper + 1], sectionKey(for: candidate) == key {
            upper += 1
        }
        return lower...upper
    }

    private func sectionKey(for button: TabButtonView) -> SectionKey {
        if button.isPinned { return .pinned }
        if let groupId = button.groupId { return .group(groupId) }
        return .loose
    }

    /// Ends the current drag: settles everything into its slot, and (when
    /// committing a drag that actually moved) tells the delegate the new
    /// model position once that settle animation finishes, so the strip isn't
    /// torn down and rebuilt underneath a pill still in flight.
    private func endDrag(commit: Bool, source: String = "internal") {
        guard let session = drag else { return }
        if let monitor = session.eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        drag = nil
        TabDragDiagnostics.record("endDrag", [
            "source": source, "commit": commit,
            "tabIndex": session.button.index, "didMove": session.didMove
        ])

        // A click that never moved needs nothing: selection already happened
        // on mouse-down, and no view left its slot.
        guard session.didMove else { return }
        if !commit {
            stripItems = session.originalItems
        }

        let sourceIndex = session.button.index
        var destination = sourceIndex
        if commit {
            // Every tab in the section, in the order they now render. That
            // section occupies one contiguous run of BrowserWindowController.
            // tabs (the [pinned][groups][loose] invariant), so the dragged
            // tab's new offset within the run, added to the run's first model
            // index, is exactly its final index in `tabs`.
            let sectionIndices: [Int] = session.range.compactMap { position in
                if case .tab(let candidate) = stripItems[position] { return candidate.index }
                return nil
            }
            if let base = sectionIndices.min(), let offset = sectionIndices.firstIndex(of: sourceIndex) {
                destination = base + offset
            }
        }

        let generation = reloadGeneration
        let frames = slotFrames()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.dropAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (position, item) in stripItems.enumerated() {
                item.view.animator().frame = frames[position]
            }
        }, completionHandler: { [weak self] in
            guard let self, commit, destination != sourceIndex else { return }
            // A reload during the settle animation means these indices
            // describe an order the model has already left behind -- the
            // reload's own layout is authoritative, so drop the move.
            guard generation == self.reloadGeneration else {
                TabDragDiagnostics.record("commitDropped", [
                    "reason": "strip-reloaded-mid-settle",
                    "sourceIndex": sourceIndex, "destinationIndex": destination
                ])
                return
            }
            TabDragDiagnostics.record("commit", [
                "sourceIndex": sourceIndex, "destinationIndex": destination
            ])
            self.delegate?.tabStripView(self, didMoveTabAt: sourceIndex, toIndex: destination)
        })
    }

    /// Drops drag state without touching any view -- for when the buttons the
    /// drag refers to are about to stop existing (see reload).
    private func abandonDrag() {
        guard let session = drag else { return }
        if let monitor = session.eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        drag = nil
    }
}
