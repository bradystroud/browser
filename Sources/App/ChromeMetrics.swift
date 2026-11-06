import AppKit

/// Shared shape and spacing metrics for the browser chrome's controls: one
/// set, read by the toolbar row, the tab strip and the floating toolbar
/// buttons alike, so the rows line up with each other by construction.
enum ChromeMetrics {
    /// The corner radius for the tab strip's controls -- tabs (horizontal
    /// and sidebar, pinned or not) and tab-group headers -- and for the
    /// find bar and the autocomplete list. The toolbar row's own controls
    /// are capsules instead (see toolbarCornerRadius).
    ///
    /// 6pt is the radius AppKit itself renders for a regular-size `.glass`
    /// bezel with a rounded-rectangle border shape (read from the bezel's
    /// own layer tree on macOS 27), and there is no public API to give that
    /// bezel any other radius.
    static let controlCornerRadius: CGFloat = 6

    /// Every control on the toolbar row is a capsule, as in Safari: the
    /// omnibox, the back/forward group, the profile pill, the toolbar
    /// buttons and the private-window badge. The glass buttons get theirs
    /// from the system bezel's own capsule border shape
    /// (`applyChromeAppearance`), and the views drawn here match it with a
    /// radius of half their height.
    static let toolbarCornerRadius: CGFloat = controlHeight / 2

    /// The radius for a shape inset by `inset` points inside a control, so
    /// its corners stay concentric with the control's own.
    static func concentricRadius(insetBy inset: CGFloat) -> CGFloat {
        max(0, controlCornerRadius - inset)
    }

    // MARK: - Rows

    /// The toolbar/omnibox row. The traffic lights sit on its centre line.
    static let toolbarHeight: CGFloat = 52
    /// The horizontal tab strip's row, below the toolbar.
    static let tabStripHeight: CGFloat = 32

    // MARK: - Controls

    /// Every control on the toolbar row: the back/forward group, the
    /// profile pill, the omnibox, the toolbar buttons and the trailing
    /// feature buttons. One height, so the capsules line up as one row.
    static let controlHeight: CGFloat = 32
    static let omniboxHeight: CGFloat = controlHeight
    /// Each half of the back/forward group.
    static let navigationSegmentWidth: CGFloat = 36

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
