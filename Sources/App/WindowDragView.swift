import AppKit

/// Empty toolbar space replaces the hidden native titlebar's drag surface.
final class WindowDragView: NSView {
    // Handle background presses explicitly so AppKit cannot start a window
    // drag before a descendant control gets a chance to handle its press.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Disabled controls can forward mouseDown up the responder chain.
        // Only a direct hit on the background should move the window.
        guard let superview,
              hitTest(superview.convert(event.locationInWindow, from: nil)) === self else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(self)
            case "None": break
            default: window?.performZoom(self)
            }
        } else {
            window?.performDrag(with: event)
        }
    }
}
