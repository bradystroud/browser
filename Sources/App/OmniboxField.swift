import AppKit

/// The omnibox text field's own subclass -- its only addition over a plain
/// NSTextField is menu(for:), which appends extra items (currently "Move
/// Tab to Profile", browser-0y1) after the field's own standard cut/copy/
/// paste context menu. menu(for:) is the standard, documented AppKit hook
/// for customizing a view's right-click menu without replacing its default
/// one, so the system editing items stay intact.
final class OmniboxField: NSTextField {
    /// Posted (with this field as the notification's object) once the field
    /// has taken focus and its expanded text is in place. The Safari-style
    /// Favourites/Recently Visited panel listens for this
    /// (OmniboxStartPanelController, browser-5kq.9) -- a notification rather
    /// than another closure property so the panel attaches without
    /// BrowserWindowController having to own or even know about it. There's
    /// no matching "did blur" notification: AppKit's own
    /// NSControl.textDidEndEditingNotification, which this field already
    /// posts, is exactly that signal.
    static let didFocusNotification = Notification.Name("OmniboxFieldDidFocus")

    /// Set by BrowserWindowController -- called with the menu about to be
    /// shown so it can append its own items. A plain closure, not a
    /// delegate protocol, matching this app's existing lightweight
    /// "feature controller sets a closure" pattern (see Tab.onFindResult/
    /// onPageMessage for the same shape).
    var onBuildContextMenu: ((NSMenu) -> Void)?

    /// Supplies the full, editable URL to show once this field takes focus.
    /// Set by BrowserWindowController; same lightweight closure pattern as
    /// onBuildContextMenu above.
    var expandedTextProvider: (() -> String?)?

    /// Swaps in the full URL and selects it the moment focus arrives -- so a
    /// click (or ⌘L) behaves like Safari's address bar: the whole URL is
    /// selected and the next keystroke replaces it.
    ///
    /// This has to happen here rather than in controlTextDidBeginEditing,
    /// which fires on the first *keystroke* too: rewriting the text there
    /// discards the character the user just typed and restores the old URL,
    /// so Enter would re-navigate to the page already open.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let text = expandedTextProvider?() {
            stringValue = text
            currentEditor()?.selectAll(nil)
        }
        // Posted last, after the expanded text is in place, so any observer
        // sees the final focused text rather than whatever was displayed
        // while collapsed.
        if accepted {
            NotificationCenter.default.post(name: Self.didFocusNotification, object: self)
        }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        onBuildContextMenu?(menu)
        return menu
    }
}
