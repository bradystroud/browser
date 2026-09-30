import AppKit

/// The omnibox text field's own subclass -- its only addition over a plain
/// NSTextField is menu(for:), which appends extra items (currently "Move
/// Tab to Profile", browser-0y1) after the field's own standard cut/copy/
/// paste context menu. menu(for:) is the standard, documented AppKit hook
/// for customizing a view's right-click menu without replacing its default
/// one, so the system editing items stay intact.
final class OmniboxField: NSTextField {
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

    /// Called whenever what the field shows changes shape: its text is
    /// replaced, or editing begins or ends. BrowserWindowController lays the
    /// pill's contents out around the displayed text (centred while
    /// collapsed), so it has to hear about both.
    var onDisplayChange: (() -> Void)?

    override var stringValue: String {
        didSet { onDisplayChange?() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSingleLine()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSingleLine()
    }

    /// The omnibox is always exactly one line. A plain NSTextField wraps a
    /// long value onto a second line and grows its intrinsic height to match,
    /// which in a fixed-height pill means the text is clipped mid-glyph
    /// instead of simply running past the right edge. `usesSingleLineMode`
    /// alone isn't enough -- the cell's own `wraps` still governs layout, and
    /// `isScrollable` is what lets the text extend beyond the visible box
    /// (and scroll with the caret) rather than being squeezed into it.
    private func configureSingleLine() {
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }

    /// Swaps in the full URL and selects it the moment focus arrives -- so a
    /// click (or ⌘L) behaves like Safari's address bar: the whole URL is
    /// selected and the next keystroke replaces it.
    ///
    /// This has to happen here rather than in controlTextDidBeginEditing,
    /// which fires on the first *keystroke* too: rewriting the text there
    /// discards the character the user just typed and restores the old URL,
    /// so Enter would re-navigate to the page already open.
    ///
    /// Editing always reads from the leading edge, so the collapsed display's
    /// centred alignment is dropped *before* the field editor is set up --
    /// the editor takes the alignment the field has when editing begins.
    override func becomeFirstResponder() -> Bool {
        let previousAlignment = alignment
        alignment = .natural
        let accepted = super.becomeFirstResponder()
        guard accepted else {
            alignment = previousAlignment
            return false
        }
        if let text = expandedTextProvider?() {
            stringValue = text
            currentEditor()?.selectAll(nil)
        }
        onDisplayChange?()
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onDisplayChange?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        onBuildContextMenu?(menu)
        return menu
    }
}
