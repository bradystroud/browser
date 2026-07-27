import AppKit

/// Small colored circle shown in a window's toolbar as a subtle per-window
/// profile identity indicator (per docs/plans/2026-07-27-browser-plan.md M1
/// scope).
final class ProfileDotView: NSView {
    var colorHex: String {
        didSet { needsDisplay = true }
    }

    init(colorHex: String) {
        self.colorHex = colorHex
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds)
        (NSColor(hex: colorHex) ?? .controlAccentColor).setFill()
        path.fill()
    }
}
