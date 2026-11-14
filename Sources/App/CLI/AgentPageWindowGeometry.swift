import AppKit

/// Only agent windows may exceed a display's size. AppKit otherwise clamps titled windows.
class AgentSizeableWindow: NSWindow {
    var permitsOffscreenAgentSizing = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        permitsOffscreenAgentSizing ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

enum AgentPageWindowGeometry {
    enum SizingError: Error, LocalizedError {
        case unavailable, mismatch(expected: NSSize, actual: NSSize)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The agent page has no live content view."
            case .mismatch(let expected, let actual):
                return "The page host reached \(Int(actual.width))x\(Int(actual.height)), expected \(Int(expected.width))x\(Int(expected.height))."
            }
        }
    }

    static func resize(window: NSWindow, requested: NSSize, isViewport: Bool,
                       host: () -> NSView?, layout: () -> Void) throws {
        window.layoutIfNeeded()
        layout()
        guard let content = window.contentView, let view = host() else { throw SizingError.unavailable }
        let original = window.frame
        let size = isViewport ? contentSize(viewport: requested, content: content.bounds.size, host: view.bounds.size) : requested
        window.setContentSize(size)
        layout()
        window.layoutIfNeeded()
        if isViewport, view.bounds.size != requested {
            let actual = view.bounds.size
            window.setFrame(original, display: false)
            layout()
            throw SizingError.mismatch(expected: requested, actual: actual)
        }
    }

    static func contentSize(viewport: NSSize, content: NSSize, host: NSSize) -> NSSize {
        NSSize(width: viewport.width + content.width - host.width,
               height: viewport.height + content.height - host.height)
    }

    static func visibleFrame(_ frame: NSRect, screens: [NSRect], preferred: NSRect?) -> NSRect {
        let titlebar = NSRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
        if screens.contains(where: { $0.intersection(titlebar).width >= min(120, frame.width) && $0.intersection(titlebar).height >= 20 }) {
            return frame
        }
        guard let screen = preferred ?? screens.first else { return frame }
        var placed = frame
        placed.origin.x = screen.minX + max(0, (screen.width - frame.width) / 2)
        placed.origin.y = screen.maxY - frame.height
        return placed
    }
}
