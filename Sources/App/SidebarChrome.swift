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
    /// True while the omnibox has the keyboard, which keeps a revealed
    /// sidebar out however far the pointer wanders.
    var isOmniboxEditing: () -> Bool = { false }
    /// True while something covers the whole window (Tab Overview), so the
    /// pointer reaching the edge does not bring the sidebar out under it.
    var isRevealSuppressed: () -> Bool = { false }
    /// The window's profile was renamed or recoloured; the sidebar's tint
    /// follows the profile colour.
    var onProfileChanged: (() -> Void)?

    private(set) var isActive = false
    /// Out because the pointer reached the edge (or ⌘L asked for the
    /// omnibox, or a popover is hung from the column) while the sidebar is
    /// set to hidden.
    private(set) var isRevealed = false
    private var revealTimer: Timer?
    private var concealTimer: Timer?
    /// Things that need a revealed sidebar to stay out regardless of the
    /// pointer: a popover or prompt hung from a view in the column. While
    /// this is above zero the sidebar does not hide.
    private var holdCount = 0
    /// A hold taken for a popover that is about to be shown, waiting to
    /// learn which popover it is (see holdOpenForNextPopover).
    private var hasPendingPopoverHold = false
    private var heldPopovers = Set<ObjectIdentifier>()
    private var observers: [NSObjectProtocol] = []
    private var hideButtonEdge: SidebarEdge?

    var edge: SidebarEdge { SidebarLayoutPreference.edge }
    var isShown: Bool { !SidebarLayoutPreference.isHidden || isRevealed }

    init() {
        hideButton.target = self
        hideButton.action = #selector(hideButtonTapped)
        hotZone.onEnter = { [weak self] in self?.pointerReachedEdge() }
        hotZone.onExit = { [weak self] in self?.revealTimer?.invalidate() }
        columnTracker.onExit = { [weak self] in self?.scheduleConceal() }
        overflowButton.target = self
        overflowButton.action = #selector(overflowButtonTapped(_:))
        footerView.addSubview(overflowButton)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .sidebarLayoutPreferenceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // An explicit show or hide replaces any reveal in progress.
            self.isRevealed = false
            self.revealTimer?.invalidate()
            self.concealTimer?.invalidate()
            if self.isActive { self.onLayoutNeeded?() }
        })
        observers.append(center.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.onProfileChanged?()
        })
        observers.append(center.addObserver(
            forName: NSPopover.willShowNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.hasPendingPopoverHold, let popover = notification.object as? NSPopover else { return }
            self.hasPendingPopoverHold = false
            self.heldPopovers.insert(ObjectIdentifier(popover))
        })
        observers.append(center.addObserver(
            forName: NSPopover.didCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let popover = notification.object as? NSPopover,
                  self.heldPopovers.remove(ObjectIdentifier(popover)) != nil else { return }
            self.endHold()
        })
    }

    deinit {
        revealTimer?.invalidate()
        concealTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
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
            holdCount = 0
            hasPendingPopoverHold = false
            heldPopovers.removeAll()
            overflowedControls = []
            unparkAll()
            return
        }
        let column = Self.columnMask(for: edge)
        if hideButtonEdge != edge {
            hideButtonEdge = edge
            hideButton.image = NSImage(
                systemSymbolName: edge == .left ? "sidebar.left" : "sidebar.right",
                accessibilityDescription: "Hide Sidebar"
            )
        }
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
    /// omnibox can be seen. It goes away again once the omnibox loses the
    /// keyboard and the pointer is elsewhere.
    func revealForOmnibox() {
        guard isActive, !isShown else { return }
        reveal()
    }

    func omniboxDidEndEditing() {
        guard isActive, isRevealed else { return }
        scheduleConceal()
    }

    private func pointerReachedEdge() {
        guard isActive, !isShown, !isRevealSuppressed() else { return }
        revealTimer?.invalidate()
        revealTimer = Self.makeTimer(after: Self.revealDelay) { [weak self] in
            guard let self, self.isActive, !self.isShown, !self.isRevealSuppressed(),
                  self.hotZone.containsPointer else { return }
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

    private func conceal() {
        revealTimer?.invalidate()
        concealTimer?.invalidate()
        guard isRevealed else { return }
        isRevealed = false
        onLayoutNeeded?()
    }

    private func scheduleConceal() {
        guard isRevealed, holdCount == 0 else { return }
        concealTimer?.invalidate()
        concealTimer = Self.makeTimer(after: Self.concealDelay) { [weak self] in
            guard let self, self.isRevealed, self.holdCount == 0 else { return }
            // Still wanted: pointer back in the column, a button held (a tab
            // drag, a resize), or the omnibox has the keyboard. Ask again
            // later.
            if self.columnTracker.containsPointer || NSEvent.pressedMouseButtons != 0 || self.isOmniboxEditing() {
                self.scheduleConceal()
                return
            }
            self.conceal()
        }
    }

    /// Default run-loop mode only, deliberately: a menu opened from the
    /// sidebar runs in event-tracking mode, and the sidebar must not vanish
    /// from under a menu that is still open. The timer fires once that menu
    /// closes and checks the pointer then. Popovers run no tracking loop, so
    /// the timer does fire while one is open: a popover hung from the column
    /// holds the sidebar out instead (holdOpenForNextPopover).
    private static func makeTimer(after delay: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .default)
        return timer
    }

    /// On a sidebar the pointer brought out the preference already says
    /// hidden, so the button puts that reveal away at once instead.
    @objc private func hideButtonTapped() {
        if SidebarLayoutPreference.isHidden {
            holdCount = 0
            hasPendingPopoverHold = false
            heldPopovers.removeAll()
            conceal()
        } else {
            SidebarLayoutPreference.isHidden = true
        }
    }

    // MARK: - Holding the sidebar open

    /// Call just before showing a popover hung from a view in the column. A
    /// hidden sidebar comes out first -- synchronously, so the anchor is in
    /// place by the time the popover measures it -- and stays out until that
    /// popover closes. If no popover shows before the next run-loop turn
    /// (the caller's own guard said no, or it toggled one closed), the hold
    /// lapses.
    func holdOpenForNextPopover() {
        guard isActive else { return }
        if !isShown { reveal() }
        guard isRevealed else { return }
        if hasPendingPopoverHold { endHold() }
        hasPendingPopoverHold = true
        beginHold()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasPendingPopoverHold else { return }
            self.hasPendingPopoverHold = false
            self.endHold()
        }
    }

    private func beginHold() {
        holdCount += 1
        concealTimer?.invalidate()
    }

    private func endHold() {
        guard holdCount > 0 else { return }
        holdCount -= 1
        if holdCount == 0 { scheduleConceal() }
    }

    // MARK: - Footer overflow

    /// The footer's "more" button: the trailing controls that do not fit
    /// beside the profile pill are listed in its menu, rather than drawn
    /// past the column's edge onto the page or off the window.
    let overflowButton: NSButton = {
        let button = NSButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More Controls")
        button.imagePosition = .imageOnly
        button.applyChromeAppearance(.glass)
        button.toolTip = "More"
        button.isHidden = true
        return button
    }()

    /// The trailing controls currently in the overflow menu, in slot order.
    var overflowedControls: [NSView] = [] {
        didSet { overflowButton.isHidden = overflowedControls.isEmpty }
    }

    func isOverflowed(_ view: NSView) -> Bool {
        overflowedControls.contains { $0 === view }
    }

    @objc private func overflowButtonTapped(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, view) in overflowedControls.enumerated() {
            let button = view as? NSButton
            let title = [button?.toolTip, view.accessibilityLabel(), button?.title]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "Control \(index + 1)"
            let item = NSMenuItem(title: title, action: #selector(overflowItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            if let image = button?.image?.copy() as? NSImage {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            }
            item.isEnabled = (view as? NSControl)?.isEnabled ?? true
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Presses an overflowed control. It stands where the overflow button is
    /// for the length of the press, so a menu it pops up from itself opens
    /// there rather than off the window; a popover it shows asks
    /// BrowserWindowController.popoverAnchor(for:), which hands out the
    /// overflow button for it.
    @objc private func overflowItemChosen(_ sender: NSMenuItem) {
        guard overflowedControls.indices.contains(sender.tag),
              let control = overflowedControls[sender.tag] as? NSControl,
              let host = control.superview, footerView.window != nil else { return }
        let parkedFrame = control.frame
        let presented = footerView.convert(overflowButton.frame, to: host)
        control.frame = presented
        control.performClick(nil)
        if control.frame == presented { control.frame = parkedFrame }
    }

    // MARK: - Parked controls

    /// What a parked control's own focus and accessibility settings were,
    /// so unparking puts back exactly what its owner chose.
    private struct ParkedState {
        weak var view: NSView?
        let refusedFirstResponder: Bool
        let wasAccessibilityElement: Bool
    }

    private var parked: [ObjectIdentifier: ParkedState] = [:]

    /// A trailing control moved out of the window (sidebar hidden, or in the
    /// overflow menu) is still unhidden -- its owner decides that -- so it
    /// leaves the key-view loop and the accessibility tree instead.
    func setParked(_ view: NSView, _ isParked: Bool) {
        let key = ObjectIdentifier(view)
        if isParked {
            guard parked[key] == nil else { return }
            let control = view as? NSControl
            parked[key] = ParkedState(
                view: view, refusedFirstResponder: control?.refusesFirstResponder ?? false,
                wasAccessibilityElement: view.isAccessibilityElement()
            )
            control?.refusesFirstResponder = true
            view.setAccessibilityElement(false)
            if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        } else if let state = parked.removeValue(forKey: key) {
            (view as? NSControl)?.refusesFirstResponder = state.refusedFirstResponder
            view.setAccessibilityElement(state.wasAccessibilityElement)
        }
    }

    func unparkAll() {
        for state in parked.values {
            guard let view = state.view else { continue }
            (view as? NSControl)?.refusesFirstResponder = state.refusedFirstResponder
            view.setAccessibilityElement(state.wasAccessibilityElement)
        }
        parked.removeAll()
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
