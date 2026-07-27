import AppKit

/// Installs a global keyDown monitor for Ctrl+Tab (next tab, wrapping) and
/// Ctrl+Shift+Tab (previous tab, wrapping) -- the macOS-standard tab-cycling
/// binding, matching Safari/Chrome.
///
/// Deliberately implemented via a raw NSEvent monitor rather than a menu
/// item's keyEquivalent: AppKit's key-equivalent routing
/// (-[NSApplication sendEvent:] -> mainMenu.performKeyEquivalent:) only
/// fires for Command-held events in practice (confirmed empirically while
/// building the keyboard-shortcuts overlay -- a bare, non-Command keyDown
/// never reaches it), and Ctrl+Tab has no Command modifier. A local monitor
/// intercepts the keyDown unconditionally instead, matching the same
/// reliable pattern ShortcutsOverlayController uses for bare "?".
///
/// Bare Tab and bare Shift+Tab are deliberately left completely alone --
/// this monitor only matches when Control is held, so normal field/view
/// navigation (moving focus forward/backward with Tab/Shift+Tab, in the
/// omnibox or on a web page) is untouched.
final class TabCyclingController {
    static let shared = TabCyclingController()

    private static let tabKeyCode: UInt16 = 48 // kVK_Tab

    private var keyMonitor: Any?

    private init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.tabKeyCode else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.control) else { return event }
            guard let controller = WindowManager.shared.keyBrowserWindowController else { return event }

            if mods.contains(.shift) {
                controller.selectPreviousTab(nil)
            } else {
                controller.selectNextTab(nil)
            }
            return nil
        }
    }
}
