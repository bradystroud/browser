import AppKit

/// Shared shape metrics for the browser chrome's controls.
enum ChromeMetrics {
    /// The one corner radius for every control in the toolbar and tab strip:
    /// tabs (horizontal and sidebar, pinned or not), tab-group headers, the
    /// omnibox, the profile pill, the "+" button, the trailing toolbar
    /// buttons and the private-window badge. They are rounded rectangles,
    /// never capsules.
    ///
    /// 6pt is the radius AppKit itself renders for a regular-size `.glass`
    /// bezel with a rounded-rectangle border shape (read from the bezel's
    /// own layer tree on macOS 27), and there is no public API to give that
    /// bezel any other radius. Matching it is what lets the glass buttons
    /// keep their real system bezel -- material, pointer response, pressed
    /// animation -- while still sharing one shape with the controls drawn
    /// here. At the chrome's control heights (24pt tabs, 28-32pt buttons,
    /// the 30pt omnibox) it stays well short of half the height, so every
    /// control reads as a rectangle with rounded corners rather than a pill.
    static let controlCornerRadius: CGFloat = 6

    /// The radius for a shape inset by `inset` points inside a control, so
    /// its corners stay concentric with the control's own.
    static func concentricRadius(insetBy inset: CGFloat) -> CGFloat {
        max(0, controlCornerRadius - inset)
    }
}
