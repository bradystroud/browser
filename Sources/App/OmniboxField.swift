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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        onBuildContextMenu?(menu)
        return menu
    }
}
