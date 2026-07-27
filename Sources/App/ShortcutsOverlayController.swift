import AppKit

/// Manages the "Keyboard Shortcuts" overlay's show/hide lifecycle and the
/// event monitors that open and dismiss it.
///
/// - ⌘/ always opens it, routed through the normal menu system (see
///   MainMenuBuilder's Help menu) rather than a monitor here -- Command-
///   modified keys are never typed as characters into any text field, web or
///   native, so this one needs no focus gating.
/// - Bare "?" (Shift+/) also opens it, via the keyDown monitor below, but
///   ONLY when native chrome has focus (not the omnibox mid-edit, not the
///   active tab's CEF content view) -- otherwise typing "?" into the omnibox
///   or a focused element on the page must just type the character. CEF's
///   content view doesn't expose whether a page-level input is focused at
///   the AppKit layer, so "native chrome has focus" is the closest
///   dependable proxy; see BrowserWindowController.isNativeChromeFocused.
/// - Escape, pressing "?" (or ⌘/) again, or a click outside the panel all
///   dismiss it.
final class ShortcutsOverlayController {
    static let shared = ShortcutsOverlayController()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private var isShowing: Bool { panel != nil }

    private init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    func toggle(relativeTo parentWindow: NSWindow?) {
        if isShowing {
            dismiss()
        } else {
            show(relativeTo: parentWindow)
        }
    }

    private func show(relativeTo parentWindow: NSWindow?) {
        guard panel == nil else { return }
        let panel = ShortcutsOverlayPanelFactory.makePanel()
        self.panel = panel

        if let parentWindow {
            let parentFrame = parentWindow.frame
            panel.setFrameOrigin(NSPoint(
                x: parentFrame.midX - panel.frame.width / 2,
                y: parentFrame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
    }

    private func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        removeDismissMonitors()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if isShowing {
            guard event.keyCode == 53 || isSlashKey(event) else { return event }
            dismiss()
            return nil
        }

        guard isSlashKey(event), !event.modifierFlags.contains(.command) else { return event }
        guard let controller = WindowManager.shared.keyBrowserWindowController,
              controller.isNativeChromeFocused else {
            return event
        }
        show(relativeTo: controller.window)
        return nil
    }

    private func isSlashKey(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == "/"
    }

    private func installDismissMonitors() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            self.dismiss()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeDismissMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }
}
