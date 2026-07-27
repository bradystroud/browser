import AppKit

/// Custom NSWindow so ⌘1-9 (select tab N) can be handled directly -- unlike
/// the other shortcuts (⌘T, ⌘W, ⌘L, ⌘R, ⌘←/→, ⌘⇧[ / ⌘⇧], ⌘⇧C), digit tab
/// selection isn't exposed as a menu item (nine near-identical menu entries
/// would be clutter, and no mainstream browser does this either), so there is
/// no menu-key-equivalent to intercept it first.
final class BrowserWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
           let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), (1...9).contains(digit),
           let controller = windowController as? BrowserWindowController {
            controller.selectTab(at: digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
