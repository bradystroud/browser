import AppKit

/// When Escape may close something laid over or around a page -- a link
/// peek, a little window. One rule for both, so Escape means the same thing
/// wherever a page sits.
///
/// Escape belongs to whatever has focus when that is the page (leaving video
/// fullscreen, closing its own dialog, cancelling an IME composition) or a
/// native text field such as the omnibox. Taking it there would throw away
/// what the user was doing. Only Escape with no modifiers counts.
enum EscapeDismissal {
    static func shouldDismiss(for event: NSEvent, in window: NSWindow?, pageHost: NSView?) -> Bool {
        guard event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        return !focusWantsEscape(in: window, pageHost: pageHost)
    }

    private static func focusWantsEscape(in window: NSWindow?, pageHost: NSView?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if (responder as? NSTextView)?.isFieldEditor == true { return true }
        guard let view = responder as? NSView, let pageHost else { return false }
        return view.isDescendant(of: pageHost)
    }
}
