import AppKit

/// Shared shape and spacing metrics for the browser chrome's controls: one
/// set, read by the toolbar row, the tab strip and the floating toolbar
/// buttons alike, so the rows line up with each other by construction.
enum ChromeMetrics {
    /// The one corner radius for every control in the toolbar and tab strip:
    /// tabs (horizontal and sidebar, pinned or not), tab-group headers, the
    /// omnibox, the back/forward group, the profile pill, the "+" button,
    /// the trailing toolbar buttons and the private-window badge. They are
    /// rounded rectangles, never capsules.
    ///
    /// 6pt is the radius AppKit itself renders for a regular-size `.glass`
    /// bezel with a rounded-rectangle border shape (read from the bezel's
    /// own layer tree on macOS 27), and there is no public API to give that
    /// bezel any other radius. Matching it is what lets the glass buttons
    /// keep their real system bezel -- material, pointer response, pressed
    /// animation -- while still sharing one shape with the controls drawn
    /// here. At the chrome's control heights (24pt tabs, 28pt buttons, the
    /// 30pt omnibox) it stays well short of half the height, so every
    /// control reads as a rectangle with rounded corners rather than a pill.
    static let controlCornerRadius: CGFloat = 6

    /// The radius for a shape inset by `inset` points inside a control, so
    /// its corners stay concentric with the control's own.
    static func concentricRadius(insetBy inset: CGFloat) -> CGFloat {
        max(0, controlCornerRadius - inset)
    }

    // MARK: - Rows

    /// The toolbar/omnibox row. The traffic lights sit on its centre line.
    static let toolbarHeight: CGFloat = 44
    /// The horizontal tab strip's row, below the toolbar.
    static let tabStripHeight: CGFloat = 32

    // MARK: - Controls

    /// Every button-like toolbar control: the back/forward group, the
    /// profile pill, the "+" and the trailing feature buttons.
    static let controlHeight: CGFloat = 28
    /// The omnibox is 2pt taller than the buttons around it. It is the one
    /// text field in the row and the thing the row exists for; the extra
    /// point above and below the 13pt text keeps its glyphs off the pill's
    /// edges and lets it read as the primary element without breaking the
    /// shared centre line.
    static let omniboxHeight: CGFloat = 30
    /// Each half of the back/forward group.
    static let navigationSegmentWidth: CGFloat = 30

    // MARK: - Spacing

    /// Between two controls in the same group (back/forward and the
    /// trailing buttons, adjacent tabs).
    static let controlSpacing: CGFloat = 6
    /// Between groups: traffic lights to navigation, navigation to the
    /// profile pill, either side of the omnibox.
    static let groupSpacing: CGFloat = 12
    /// Leading and trailing inset of both rows. The traffic lights, the
    /// first tab and the trailing "+" all sit this far in from the window's
    /// edges, so the two rows line up with each other.
    static let edgeInset: CGFloat = 10
}
