import AppKit

@main
struct AgentPageWindowGeometryTests {
    static func main() throws {
        _ = NSApplication.shared
        let window = AgentSizeableWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                                        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.permitsOffscreenAgentSizing = true
        guard let content = window.contentView else { fatalError("Missing native content view") }
        let host = NSView()
        content.addSubview(host)
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 142))
        content.addSubview(chrome)
        let layout = {
            host.frame = NSRect(x: 0, y: 0, width: content.bounds.width,
                                height: content.bounds.height - chrome.bounds.height)
        }
        layout()
        for size in [NSSize(width: 1920, height: 1080), NSSize(width: 390, height: 844),
                     NSSize(width: 4096, height: 2160), NSSize(width: 800, height: 600)] {
            try AgentPageWindowGeometry.resize(window: window, requested: size, isViewport: true,
                                               host: { host }, layout: layout)
            precondition(host.bounds.size == size, "Production resize did not reach the requested host size")
            precondition(!window.isVisible && !window.isKeyWindow)
        }
        // A broken layout must fail and restore the original frame.
        let original = window.frame
        do {
            try AgentPageWindowGeometry.resize(window: window, requested: NSSize(width: 1280, height: 720),
                                               isViewport: true, host: { host }, layout: {})
            preconditionFailure("A stale host was reported as successfully resized")
        } catch AgentPageWindowGeometry.SizingError.mismatch { precondition(window.frame == original) }
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1040)
        let second = NSRect(x: 1920, y: 0, width: 1920, height: 1040)
        let positioned = NSRect(x: 2040, y: 100, width: 800, height: 600)
        precondition(AgentPageWindowGeometry.visibleFrame(positioned, screens: [screen, second], preferred: screen) == positioned)
        let hidden = NSRect(x: -10000, y: -10000, width: 4096, height: 2302)
        let shown = AgentPageWindowGeometry.visibleFrame(hidden, screens: [screen], preferred: screen)
        precondition(shown.size == hidden.size && shown.maxY == screen.maxY)
        precondition(window.constrainFrameRect(hidden, to: NSScreen.main) == hidden)
        window.permitsOffscreenAgentSizing = false
        precondition(window.constrainFrameRect(hidden, to: NSScreen.main) ==
                     NSWindow(contentRect: .zero, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                        .constrainFrameRect(hidden, to: NSScreen.main))
        print("Native viewport: production resize, rollback, oversized placement and normal-window constraints passed")
    }
}
