import AppKit

/// The sidebar layout (TabStripOrientation.sidebar): one full-height column on
/// the left or right edge carrying everything the toolbar row normally does,
/// with the page filling the rest of the window as an inset, round-cornered
/// card.
///
/// Column, top to bottom:
///
/// - a navigation row level with the traffic lights: the lights, a hide-
///   sidebar button and the back/forward group;
/// - the omnibox pill, full column width;
/// - the vertical TabStripView, unchanged -- pinned favicon grid, group
///   folders, tabs, and its own New Tab row;
/// - a footer with the profile pill on the leading side and the trailing
///   toolbar controls (Reader, Downloads, password key, extensions) packed
///   against the trailing side.
///
/// BrowserWindowController still owns every one of those views and frames
/// them; this type owns only what exists for this layout alone (the footer,
/// the hide button, the edge hot zone) plus the geometry, so the controller
/// only has to ask where things go.
///
/// The page is never overlapped. Showing a hidden sidebar *shrinks* the page,
/// exactly as showing it permanently does, rather than sliding a panel over
/// it -- CEF's surface paints over any AppKit view in its region (see
/// BrowserWindowController.contentAreaTopY). For the same reason the reveal
/// is not animated: every intermediate frame would be a renderer resize.
final class SidebarChrome {
    static let width = TabStripView.sidebarWidth
    /// The margin between the page card and the window edge on the sides the
    /// sidebar is not on. It is also what makes the hidden sidebar reachable:
    /// the page never reaches the window edge, so the margin on the sidebar's
    /// side is plain AppKit space a tracking area can watch.
    static let pageInset: CGFloat = 8
    static let pageCornerRadius: CGFloat = 10
    /// Level with the traffic lights, which BrowserWindow centres on
    /// toolbarHeight / 2 below the top of the window's chrome.
    static let navigationRowHeight = ChromeMetrics.toolbarHeight
    static let omniboxRowHeight = ChromeMetrics.omniboxHeight + 10
    static var headerHeight: CGFloat { navigationRowHeight + omniboxRowHeight }
    static let footerHeight: CGFloat = 44

    /// How long the pointer has to rest on the hot zone before the sidebar
    /// comes out, so a window resize from that edge, or a pointer passing
    /// through on its way off the window, does not flash it.
    private static let revealDelay: TimeInterval = 0.12
    /// How long after the pointer leaves the column it goes away again.
    private static let concealDelay: TimeInterval = 0.4

    struct Frames {
        /// The whole column, in the window's contentView coordinates.
        var column: NSRect
        var header: NSRect
        var tabList: NSRect
        var footer: NSRect
        var page: NSRect
        var hotZone: NSRect
    }

    let footerView = WindowDragView()
    let hideButton: NSButton = {
        let button = NSButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Hide Sidebar")
        button.imagePosition = .imageOnly
        button.applyChromeAppearance(.inline)
        button.toolTip = "Hide Sidebar"
        return button
    }()
    private let hotZone = SidebarTrackingView()
    private let columnTracker = SidebarTrackingView()

    /// Re-run the window's chrome layout; called whenever the sidebar shows
    /// or hides itself.
    var onLayoutNeeded: (() -> Void)?
    /// True while the omnibox is being edited, which keeps a revealed sidebar
    /// out however far the pointer wanders.
    var isOmniboxEditing: () -> Bool = { false }

    private(set) var isActive = false
    /// Out because the pointer reached the edge (or ⌘L asked for the
    /// omnibox) while the sidebar is set to hidden.
    private(set) var isRevealed = false
    private var revealTimer: Timer?
    private var concealTimer: Timer?

    var edge: SidebarEdge { SidebarLayoutPreference.edge }
    var isShown: Bool { !SidebarLayoutPreference.isHidden || isRevealed }

    init() {
        hideButton.target = self
        hideButton.action = #selector(hideButtonTapped)
        hotZone.onEnter = { [weak self] in self?.pointerReachedEdge() }
        hotZone.onExit = { [weak self] in self?.revealTimer?.invalidate() }
        columnTracker.onExit = { [weak self] in self?.scheduleConceal() }
        NotificationCenter.default.addObserver(
            forName: .sidebarLayoutPreferenceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // An explicit show or hide replaces any reveal in progress.
            self.isRevealed = false
            self.revealTimer?.invalidate()
            self.concealTimer?.invalidate()
            if self.isActive { self.onLayoutNeeded?() }
        }
    }

    deinit {
        revealTimer?.invalidate()
        concealTimer?.invalidate()
    }

    /// Adds this layout's own views. The footer goes in the content view
    /// (BrowserWindowController moves the profile pill and private badge into
    /// it), the hide button in the header, and the two tracking views behind
    /// everything -- they never take a click (see SidebarTrackingView).
    func install(in contentView: NSView, header: NSView) {
        contentView.addSubview(hotZone, positioned: .below, relativeTo: nil)
        contentView.addSubview(columnTracker, positioned: .below, relativeTo: nil)
        contentView.addSubview(footerView)
        header.addSubview(hideButton)
        apply(nil)
    }

    /// Where everything goes for the current edge and shown state.
    /// `topInset` is the dev-build banner's height, which the whole layout
    /// sits below.
    func frames(in bounds: NSRect, topInset: CGFloat) -> Frames {
        let width = Self.width
        let height = max(0, bounds.height - topInset)
        let inset = Self.pageInset
        let columnX = edge == .left ? 0 : bounds.width - width
        let pageWidth = isShown ? bounds.width - width - inset : bounds.width - inset * 2
        let pageX: CGFloat
        switch (edge, isShown) {
        case (.left, true): pageX = width
        case (.right, true), (_, false): pageX = inset
        }
        return Frames(
            column: NSRect(x: columnX, y: 0, width: width, height: height),
            header: NSRect(x: columnX, y: height - Self.headerHeight, width: width, height: Self.headerHeight),
            tabList: NSRect(
                x: columnX, y: Self.footerHeight,
                width: width, height: max(0, height - Self.headerHeight - Self.footerHeight)
            ),
            footer: NSRect(x: columnX, y: 0, width: width, height: Self.footerHeight),
            page: NSRect(x: pageX, y: inset, width: max(0, pageWidth), height: max(0, height - inset * 2)),
            hotZone: NSRect(x: edge == .left ? 0 : bounds.width - inset, y: 0, width: inset, height: height)
        )
    }

    /// The column's own views for `frames`, or `nil` to put the layout away
    /// (any other orientation).
    func apply(_ frames: Frames?) {
        isActive = frames != nil
        guard let frames else {
            footerView.isHidden = true
            hideButton.isHidden = true
            hotZone.isHidden = true
            columnTracker.isHidden = true
            isRevealed = false
            revealTimer?.invalidate()
            concealTimer?.invalidate()
            return
        }
        let column = Self.columnMask(for: edge)
        footerView.isHidden = !isShown
        footerView.frame = frames.footer
        footerView.autoresizingMask = column.union(.maxYMargin)
        hideButton.isHidden = false
        hotZone.isHidden = isShown
        hotZone.frame = frames.hotZone
        hotZone.autoresizingMask = column.union(.height)
        columnTracker.isHidden = !isRevealed
        columnTracker.frame = frames.column
        columnTracker.autoresizingMask = column.union(.height)
        // Unhiding alone does not reliably re-arm a tracking area.
        hotZone.updateTrackingAreas()
        columnTracker.updateTrackingAreas()
    }

    /// Autoresizing for anything pinned to the column: a fixed width that
    /// stays against the sidebar's edge as the window resizes.
    static func columnMask(for edge: SidebarEdge) -> NSView.AutoresizingMask {
        edge == .left ? .maxXMargin : .minXMargin
    }

    /// Navigation-row controls in the header's own coordinates: the back/
    /// forward group against the column's trailing edge, the hide button
    /// just before it, both on the traffic lights' centre line.
    func navigationGroupFrame(width groupWidth: CGFloat) -> NSRect {
        let height = ChromeMetrics.controlHeight
        return NSRect(
            x: Self.width - ChromeMetrics.edgeInset - groupWidth,
            y: (Self.headerHeight - Self.navigationRowHeight / 2 - height / 2).rounded(),
            width: groupWidth, height: height
        )
    }

    func layoutHideButton(beside navigationGroup: NSRect) {
        let size = ChromeMetrics.controlHeight
        hideButton.frame = NSRect(
            x: navigationGroup.minX - ChromeMetrics.controlSpacing - size, y: navigationGroup.minY,
            width: size, height: size
        )
    }

    /// The omnibox pill, full column width less the edge insets, centred in
    /// its row under the navigation row. The same whether or not it is
    /// focused: there is no wider band for it to grow into.
    var omniboxFrame: NSRect {
        let height = ChromeMetrics.omniboxHeight
        return NSRect(
            x: ChromeMetrics.edgeInset, y: ((Self.omniboxRowHeight - height) / 2).rounded(),
            width: Self.width - ChromeMetrics.edgeInset * 2, height: height
        )
    }

    // MARK: - Reveal on hover

    /// ⌘L or a new tab while the sidebar is hidden: bring it out so the
    /// omnibox can be seen. It goes away again once editing ends and the
    /// pointer is elsewhere.
    func revealForOmnibox() {
        guard isActive, !isShown else { return }
        reveal()
    }

    func omniboxDidEndEditing() {
        guard isActive, isRevealed else { return }
        scheduleConceal()
    }

    private func pointerReachedEdge() {
        guard isActive, !isShown else { return }
        revealTimer?.invalidate()
        revealTimer = Self.makeTimer(after: Self.revealDelay) { [weak self] in
            guard let self, self.isActive, !self.isShown, self.hotZone.containsPointer else { return }
            self.reveal()
        }
    }

    private func reveal() {
        isRevealed = true
        onLayoutNeeded?()
        // Polled rather than left to the tracker's exit event alone: the
        // tracker was hidden when the pointer arrived, so AppKit may never
        // have counted it as inside, and a ⌘L reveal never had the pointer
        // there at all. The exit event only makes the common case quicker.
        scheduleConceal()
    }

    private func scheduleConceal() {
        guard isRevealed else { return }
        concealTimer?.invalidate()
        concealTimer = Self.makeTimer(after: Self.concealDelay) { [weak self] in
            guard let self, self.isRevealed else { return }
            // Still wanted: pointer back in the column, a button held (a tab
            // drag, a resize), or the omnibox mid-edit. Ask again later.
            if self.columnTracker.containsPointer || NSEvent.pressedMouseButtons != 0 || self.isOmniboxEditing() {
                self.scheduleConceal()
                return
            }
            self.isRevealed = false
            self.onLayoutNeeded?()
        }
    }

    /// Default run-loop mode only, deliberately: a context menu or popover
    /// opened from the sidebar runs in event-tracking mode, and the sidebar
    /// must not vanish from under a menu that is still open. The timer fires
    /// once that menu closes and checks the pointer then.
    private static func makeTimer(after delay: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .default)
        return timer
    }

    @objc private func hideButtonTapped() {
        SidebarLayoutPreference.isHidden = true
    }
}

/// A view that only watches the pointer: it reports entering and leaving its
/// own bounds and never takes a click, so it can sit anywhere in the window
/// without getting in the way of what is drawn over it.
private final class SidebarTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var containsPointer: Bool {
        guard !isHidden, let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHidden else { return }
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isHidden else { return }
        onExit?()
    }
}
