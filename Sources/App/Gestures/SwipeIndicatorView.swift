import AppKit

/// The disc a sideways swipe brings in from the page edge: an arrow inside
/// a ring that winds round as the fingers go and closes when letting go
/// would navigate. It follows the fingers directly, with no spring, since a
/// spring reads as lag on a quick flick.
///
/// Drawn in draw(_:) with dynamic system colors, so it follows light and
/// dark appearance without any bookkeeping.
final class SwipeIndicatorView: NSView {
    /// Room around the disc for its shadow and the commit animation's
    /// slight growth.
    static let margin: CGFloat = 20

    private var state: SwipeIndicatorState?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Positions the disc against `pageFrame` (in the superview's
    /// coordinates) for `state`.
    func show(_ state: SwipeIndicatorState, in pageFrame: NSRect) {
        self.state = state
        let diameter = CGFloat(SwipeIndicatorGeometry.diameter)
        let inset = CGFloat(SwipeIndicatorGeometry.edgeInset(for: state))
        let side = diameter + Self.margin * 2
        let discX = state.direction == .back
            ? pageFrame.minX + inset
            : pageFrame.maxX - inset - diameter
        frame = NSRect(x: discX - Self.margin, y: pageFrame.midY - side / 2, width: side, height: side)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        let diameter = CGFloat(SwipeIndicatorGeometry.diameter) * CGFloat(SwipeIndicatorGeometry.scale(for: state))
        let disc = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        let hairline = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
        hairline.lineWidth = 1
        hairline.stroke()

        if state.progress > 0 {
            let ring = NSBezierPath()
            let radius = diameter / 2 - 1.5
            let center = NSPoint(x: disc.midX, y: disc.midY)
            // Flipped coordinates: -90 degrees is the top, and increasing
            // angles run clockwise on screen.
            ring.appendArc(withCenter: center, radius: radius, startAngle: -90,
                           endAngle: -90 + 360 * CGFloat(state.progress), clockwise: false)
            ring.lineWidth = 2
            ring.lineCapStyle = .round
            (state.isArmed ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.55)).setStroke()
            ring.stroke()
        }

        let symbol = state.direction == .back ? "arrow.left" : "arrow.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let tint = NSColor.labelColor.withAlphaComponent(0.4 + 0.6 * CGFloat(state.progress))
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let imageRect = NSRect(x: disc.midX - image.size.width / 2, y: disc.midY - image.size.height / 2,
                               width: image.size.width, height: image.size.height)
        tinted.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
