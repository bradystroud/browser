import AppKit

/// The slim and hidden tab columns of the "Tabs Down the Side" layout
/// (VerticalTabsPresentation): the column is a narrow strip of favicons, or
/// only a few points of margin at the window's edge, and it widens to the
/// full list while the pointer is on it.
///
/// The page is never overlapped and never resized. It is laid out against
/// the slim width for good, and when the column widens the page *slides*
/// aside by the same amount, its far edge leaving the window. A slide is a
/// change of position only, so the renderer sees no resize, and Core
/// Animation moves the page's layer by itself -- which is what lets this
/// reveal be animated when the sidebar layout's cannot (see SidebarChrome).
/// The page stays live throughout: nothing stands in for it, so there is
/// nothing to restore when a tab switches, closes or changes engine while
/// the column is out. The column and the page move on the same spring from
/// the same commit, so their shared edge stays shared on every frame and no
/// AppKit view is ever in the page's region (see
/// BrowserWindowController.contentAreaTopY for why that matters).
///
/// BrowserWindowController owns the strip and the page and frames them; this
/// type owns what exists for slim tabs alone (the clip the column's material
/// sits in, the shadow at its edge, the pointer tracker) and decides when
/// the column is out.
final class SlimTabsChrome {
    /// How long the pointer has to rest on the strip before it widens, so a
    /// pointer crossing it on the way to the window's edge, or a click on a
    /// favicon, does not flash the list.
    private static let revealDelay: TimeInterval = 0.12
    /// How long after the pointer leaves the column it narrows again.
    /// Short: the wait is felt as lag before the column starts to move. It
    /// only has to outlast a pointer that slips off the edge by a few points
    /// and comes straight back.
    private static let concealDelay: TimeInterval = 0.1
    /// What a hidden column keeps at the window's leading edge. The page
    /// never reaches that edge, so these points are plain AppKit space the
    /// tracker can watch; a hot zone over the page itself would be an AppKit
    /// view in the page's region, and the page takes the pointer there.
    static let hiddenEdgeWidth: CGFloat = 6
    static let edgeShadowWidth: CGFloat = 14
    /// How far the column's material runs past its full width, so the
    /// spring's overshoot uncovers more material and not bare window.
    static let backdropOverrun: CGFloat = 32

    /// Holds the column's material at its full width and shows as much of it
    /// as the column is wide. The window controller keeps the material here
    /// for the whole "Tabs Down the Side" layout, slim or not, so the change
    /// between the two can be sprung as well. A material view resized on every frame would
    /// redraw its backdrop on every frame; a clip that changes size costs
    /// nothing.
    let backdropClip: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.isHidden = true
        return view
    }()
    /// A soft shadow just inside the widened column's edge, as if the page
    /// were a card lying on it. Inside the column, never on the page.
    let edgeShadow = SlimEdgeShadowView()
    private let tracker = SidebarTrackingView()

    /// The column widened or narrowed; frame the window's views for it.
    var onExpansionChanged: (() -> Void)?
    /// True while something covers the whole window (Tab Overview), so the
    /// pointer does not widen the column under it.
    var isExpansionSuppressed: () -> Bool = { false }
    /// True while something in the column needs it to stay wide whatever the
    /// pointer does: a view in it has the keyboard.
    var holdsExpansion: () -> Bool = { false }

    private(set) var isActive = false
    private(set) var isExpanded = false
    private var revealTimer: Timer?
    private var concealTimer: Timer?

    init() {
        tracker.onEnter = { [weak self] in self?.pointerEntered() }
        tracker.onExit = { [weak self] in
            self?.revealTimer?.invalidate()
            self?.scheduleConceal()
        }
        tracker.isHidden = true
        edgeShadow.isHidden = true
    }

    deinit {
        revealTimer?.invalidate()
        concealTimer?.invalidate()
    }

    /// The tracker goes behind everything (it never takes a click), the
    /// material's clip under the strip, the shadow over it.
    func install(in contentView: NSView, strip: NSView) {
        contentView.addSubview(tracker, positioned: .below, relativeTo: nil)
        contentView.addSubview(backdropClip, positioned: .below, relativeTo: strip)
        contentView.addSubview(edgeShadow, positioned: .above, relativeTo: strip)
    }

    private static var testCycleRan = false

    /// `--test-slim-tabs-cycle`: widens the first window's column a few
    /// seconds after it first shows, holds it, and narrows it again, so an
    /// agent can screenshot each state without moving the pointer. Once per
    /// process.
    private func runTestCycleIfRequested() {
        guard !Self.testCycleRan, CommandLine.arguments.contains("--test-slim-tabs-cycle") else { return }
        Self.testCycleRan = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.isActive else { return }
            self.isHeldForTest = true
            self.expand()
            NSLog("[slim-tabs] test cycle: widened")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.isHeldForTest = false
                self?.collapse()
                NSLog("[slim-tabs] test cycle: narrowed")
            }
        }
    }

    private var isHeldForTest = false

    /// The column's current frame in the window's contentView, or nil to put
    /// slim tabs away (any other layout, or the preference off).
    func apply(column: NSRect?) {
        isActive = column != nil
        guard let column else {
            revealTimer?.invalidate()
            concealTimer?.invalidate()
            isExpanded = false
            tracker.isHidden = true
            edgeShadow.isHidden = true
            return
        }
        tracker.isHidden = false
        edgeShadow.isHidden = false
        tracker.frame = column
        tracker.autoresizingMask = [.height, .maxXMargin]
        // Unhiding or resizing alone does not reliably re-arm a tracking area.
        tracker.updateTrackingAreas()
        runTestCycleIfRequested()
    }

    /// Forgets that the column is out without telling anyone, for an owner
    /// that is about to lay everything out again itself (the presentation
    /// changed). The pointer may still be where the column was; it has to
    /// leave and come back to bring the column out again.
    func resetExpansion() {
        revealTimer?.invalidate()
        concealTimer?.invalidate()
        isExpanded = false
    }

    /// Narrows the column at once, for whatever is about to cover the window.
    func collapse() {
        revealTimer?.invalidate()
        concealTimer?.invalidate()
        guard isExpanded else { return }
        isExpanded = false
        onExpansionChanged?()
    }

    private func pointerEntered() {
        guard isActive else { return }
        concealTimer?.invalidate()
        guard !isExpanded else {
            scheduleConceal()
            return
        }
        scheduleReveal()
    }

    private func scheduleReveal() {
        revealTimer?.invalidate()
        revealTimer = SidebarChrome.makeTimer(after: Self.revealDelay) { [weak self] in
            guard let self, self.isActive, !self.isExpanded, !self.isExpansionSuppressed(),
                  self.tracker.containsPointer else { return }
            // A button is down: a tab being dragged within the strip, a
            // selection dragged off the page, the window's edge being
            // resized. Widening would move things under that drag; look
            // again once it is over.
            guard NSEvent.pressedMouseButtons == 0 else {
                self.scheduleReveal()
                return
            }
            self.expand()
        }
    }

    private func expand() {
        isExpanded = true
        onExpansionChanged?()
        // Polled rather than left to the tracker's exit event alone: the
        // tracker has just been resized under the pointer, and AppKit does
        // not always send an exit for an area that changed while the pointer
        // was in it. The exit event only makes the common case quicker.
        scheduleConceal()
    }

    private func scheduleConceal() {
        guard isExpanded else { return }
        concealTimer?.invalidate()
        concealTimer = SidebarChrome.makeTimer(after: Self.concealDelay) { [weak self] in
            guard let self, self.isExpanded else { return }
            // Still wanted: the pointer is in the column, a button is held
            // (a tab drag), or something in the column has the keyboard. Ask
            // again later. With the app in the background the pointer's
            // position says nothing about this window.
            let pointerInColumn = NSApp.isActive && self.tracker.containsPointer
            if pointerInColumn || NSEvent.pressedMouseButtons != 0 || self.holdsExpansion() || self.isHeldForTest {
                self.scheduleConceal()
                return
            }
            self.collapse()
        }
    }
}

/// The strip along the tab column's trailing edge that the user drags to
/// resize the column. It lies inside the column, never on the page, and
/// reports the pointer's position in its superview; what a drag means (a new
/// width, or the change into and out of slim tabs) is the window
/// controller's to decide.
///
/// The drag is followed through this view's own mouseDragged and mouseUp,
/// which AppKit delivers to the view that took the mouse-down. A nested
/// event-tracking loop is ruled out: it would block the run loop the engine
/// is driven from (see BRWMessagePump in CLAUDE.md).
final class TabColumnResizeHandle: NSView {
    static let width: CGFloat = 6

    var onDragBegan: ((CGFloat) -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var isDragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    private func position(of event: NSEvent) -> CGFloat {
        (superview ?? self).convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            isDragging = false
            onDoubleClick?()
            return
        }
        isDragging = true
        onDragBegan?(position(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDragged?(position(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
    }
}

/// The gradient SlimTabsChrome lays along the widened column's edge. It never
/// takes a click.
final class SlimEdgeShadowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.05).cgColor,
            NSColor.black.withAlphaComponent(0.2).cgColor,
        ]
        gradient.locations = [0, 0.55, 1]
        layer = gradient
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Chrome animations that run entirely in the render server.
///
/// Each helper sets the view's real value at once and plays the difference
/// as an explicit layer animation on top of it. The view tree is therefore
/// always in its final state: nothing lays out per frame, hit testing never
/// sees an in-between frame, and a view that holds a web page is told about
/// one move, not sixty. The animations are additive, so one that starts
/// while another is still running (the pointer leaving a column that is
/// still widening) bends the motion instead of restarting it.
enum ChromeMotion {
    struct Spring {
        let stiffness: CGFloat
        let damping: CGFloat

        /// Slightly under-damped: the column arrives with a small overshoot.
        static let expand = Spring(stiffness: 420, damping: 33)
        /// Critically damped: going away should not bounce.
        static let collapse = Spring(stiffness: 760, damping: 55)

        fileprivate func animation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = stiffness
            animation.damping = damping
            animation.duration = animation.settlingDuration
            animation.isAdditive = true
            return animation
        }
    }

    /// Reduce Motion replaces every movement with an instant change.
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Gives `view` its new frame, sprung from the old one when `spring` is
    /// given. Sublayers are not resized frame by frame, so a view whose
    /// content should be revealed or hidden by the change must clip to its
    /// bounds.
    static func setFrame(_ view: NSView, to frame: NSRect, spring: Spring?) {
        let old = view.frame
        guard old != frame else { return }
        view.frame = frame
        guard let spring, let layer = view.layer, view.window != nil else { return }
        let anchor = layer.anchorPoint
        let widthDelta = old.width - frame.width
        let heightDelta = old.height - frame.height
        let offset = CGPoint(
            x: old.minX - frame.minX + anchor.x * widthDelta,
            y: old.minY - frame.minY + anchor.y * heightDelta)
        if offset != .zero {
            let move = spring.animation(keyPath: "position")
            move.fromValue = NSValue(point: offset)
            move.toValue = NSValue(point: .zero)
            layer.add(move, forKey: nil)
        }
        if widthDelta != 0 || heightDelta != 0 {
            let resize = spring.animation(keyPath: "bounds.size")
            resize.fromValue = NSValue(size: NSSize(width: widthDelta, height: heightDelta))
            resize.toValue = NSValue(size: .zero)
            layer.add(resize, forKey: nil)
        }
    }

    /// Gives `view` its new opacity, faded over `duration` when one is
    /// given, after `delay`, and sliding in from `slide` points to the side.
    static func setAlpha(
        _ view: NSView, to alpha: CGFloat, duration: CFTimeInterval?,
        delay: CFTimeInterval = 0, slide: CGFloat = 0
    ) {
        let layer = view.layer
        let old = layer?.presentation()?.opacity ?? Float(view.alphaValue)
        view.alphaValue = alpha
        layer?.removeAnimation(forKey: fadeKey)
        layer?.removeAnimation(forKey: slideKey)
        guard let duration, let layer, view.window != nil, old != Float(alpha) else { return }
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = old
        fade.toValue = Float(alpha)
        configure(fade, duration: duration, start: start)
        layer.add(fade, forKey: fadeKey)
        guard slide != 0 else { return }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = slide
        move.toValue = 0
        move.isAdditive = true
        configure(move, duration: duration, start: start)
        layer.add(move, forKey: slideKey)
    }

    private static let fadeKey = "chromeMotionFade"
    private static let slideKey = "chromeMotionSlide"

    private static func configure(_ animation: CABasicAnimation, duration: CFTimeInterval, start: CFTimeInterval) {
        animation.duration = duration
        animation.beginTime = start
        // Holds the starting value through the delay.
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    }
}
