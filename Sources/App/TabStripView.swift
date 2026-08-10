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

    /// How far the pointer must travel horizontally before a mouse-down is
    /// treated as a drag at all.
    private static let dragMovementThreshold: CGFloat = 4
    /// Neighbours sliding aside as the dragged pill passes them.
    private static let reflowAnimationDuration: TimeInterval = 0.14
    /// The dropped pill settling into its slot.
    private static let dropAnimationDuration: TimeInterval = 0.12

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
    /// macOS 26+ only: hosts every tab/group-header's own NSGlassEffectView
    /// so they batch-render and merge together when close, matching how
    /// Safari's own adjacent tab pills blend into each other rather than
    /// reading as separate frosted rectangles (see
    /// NSGlassEffectContainerView's own header doc comment, and browser-qpy-
    /// notes.md for the spacing value's rationale). `nil` pre-26.
    private var glassContainer: NSView?
    /// Where rebuildButtons() actually adds each tab/group-header subview --
    /// the glass container's contentView on macOS 26+, `self` otherwise (the
    /// exact pre-rework behavior). Set once, read (never reassigned after)
    /// by rebuildButtons on every reload.
    private lazy var glassContentHost: NSView = {
        guard #available(macOS 26.0, *) else { return self }
        let container = NSGlassEffectContainerView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        // Nonzero so adjacent pills within this distance visually merge
        // (the default, zero, only batches rendering -- see the class's own
        // doc comment) -- a starting guess, not verified against a real
        // render; see browser-qpy-notes.md's Deviations for why this is
        // flagged for Brady to tune once he can actually see it.
        container.spacing = 4
        let content = NSView(frame: bounds)
        content.autoresizingMask = [.width, .height]
        container.contentView = content
        addSubview(container, positioned: .below, relativeTo: nil)
        glassContainer = container
        return content
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
        // Force the glass container to be created (and added) now, before
        // newTabButton below, so the button always renders above it.
        _ = glassContentHost
        newTabButton.target = self
        newTabButton.action = #selector(newTabTapped)
        addSubview(newTabButton)
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

    override func layout() {
        super.layout()
        layoutTabs()
    }

    private func layoutTabs() {
        let frames = slotFrames()
        for (position, item) in stripItems.enumerated() {
            let view = item.view
            if let session = drag, session.didMove, view === session.button {
                // The dragged pill belongs to the cursor, not to the layout,
                // for as long as the drag lasts -- take only the slot's
                // vertical geometry (which a window resize can genuinely
                // change mid-drag) and leave its x alone.
                view.frame = NSRect(
                    x: view.frame.minX, y: frames[position].minY,
                    width: frames[position].width, height: frames[position].height
                )
            } else {
                view.frame = frames[position]
            }
        }

        newTabButton.frame = NSRect(
            x: bounds.width - Self.newTabButtonWidth - Self.sidePadding,
            y: (bounds.height - 20) / 2,
            width: 20,
            height: 20
        )

        if case .tab(let firstButton)? = stripItems.first {
            TabDragDiagnostics.probeHitTestingOnce(button: firstButton)
        }
        runDragSelfTestIfRequested()
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
    private func runDragSelfTestIfRequested() {
        guard !hasRunDragSelfTest, TabDragDiagnostics.isSelfTestRequested,
              let window, stripItems.count >= 3,
              case .tab(let button)? = stripItems.first, button.bounds.width > 0 else { return }
        hasRunDragSelfTest = true

        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
            let inWindow = convert(NSPoint(x: x, y: bounds.midY), to: nil)
            return NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }

        let startX = button.frame.midX
        // Far enough right to clear two whole slots, so the drag has to swap
        // twice and the committed index can't accidentally match the source.
        // +8 so the pill's centre lands clearly past the second slot's
        // midpoint rather than exactly on it (an exact tie doesn't swap).
        let endX = startX + button.frame.width * 2 + Self.tabSpacing * 2 + 8
        TabDragDiagnostics.record("selfTestStart", [
            "tabIndex": button.index, "startX": Double(startX), "endX": Double(endX),
            "stripItemCount": stripItems.count
        ])
        guard let down = event(.leftMouseDown, x: startX) else { return }
        tabButton(button, didBeginDragWith: down)
        for step in 1...8 {
            let x = startX + (endX - startX) * CGFloat(step) / 8
            guard let dragged = event(.leftMouseDragged, x: x) else { continue }
            tabButton(button, didDragWith: dragged)
        }
        guard let up = event(.leftMouseUp, x: endX) else { return }
        tabButton(button, didEndDragWith: up)
    }


    /// The frame each entry of `stripItems` should occupy, in the same
    /// left-to-right render order rebuildButtons established. Pinned tabs and
    /// group headers get fixed widths off the top; every other tab button
    /// (loose, or a member of an expanded group) shares whatever width
    /// remains, same even-width-down-to-a-minimum scheme as before groups
    /// existed.
    ///
    /// Pure geometry, deliberately: drag-to-reorder needs to know where slots
    /// *are* without moving anything into them (to decide when the dragged
    /// pill has crossed a neighbour) and needs to animate views into them
    /// rather than assign frames outright, neither of which the old
    /// compute-and-assign-in-one-pass layout could express. It also means
    /// every slot width within one section is identical by construction,
    /// which is what lets a drag compare against fixed slot midpoints and
    /// swap only with immediate neighbours.
    private func slotFrames() -> [NSRect] {
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
            startPoint: convert(event.locationInWindow, from: nil),
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
        let deltaX = convert(event.locationInWindow, from: nil).x - session.startPoint.x
        if !session.didMove {
            guard abs(deltaX) >= Self.dragMovementThreshold else {
                TabDragDiagnostics.record("dragBelowThreshold", [
                    "source": source, "tabIndex": button.index,
                    "deltaX": Double(deltaX), "threshold": Double(Self.dragMovementThreshold)
                ])
                return
            }
            drag?.didMove = true
            TabDragDiagnostics.record("dragThresholdCrossed", [
                "source": source, "tabIndex": button.index, "deltaX": Double(deltaX)
            ])
            // Above its neighbours for the rest of the drag, so the pill it
            // slides over never renders on top of the one being dragged.
            glassContentHost.addSubview(button, positioned: .above, relativeTo: nil)
        }

        let frames = slotFrames()
        let width = button.frame.width
        let lowerLimit = frames[session.range.lowerBound].minX
        let upperLimit = max(lowerLimit, frames[session.range.upperBound].maxX - width)
        let x = min(max(session.startFrame.minX + deltaX, lowerLimit), upperLimit)
        button.frame.origin.x = x

        // Swap past whichever neighbours the pill's centre has crossed. Slot
        // geometry is identical for every item in one section (see
        // slotFrames), so `frames` stays valid across these swaps and the
        // comparison never needs recomputing mid-loop.
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
        guard itemIndex != session.itemIndex else { return }
        drag?.itemIndex = itemIndex
        TabDragDiagnostics.record("dragReflow", [
            "source": source, "tabIndex": button.index,
            "fromItemIndex": session.itemIndex, "toItemIndex": itemIndex
        ])
        applySlotFrames(animated: true, skipping: button)
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
