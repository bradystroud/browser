import Foundation

/// Whether ⌥⇧-clicking a link peeks at it instead of opening a new window.
///
/// On by default: ⌥⇧-click has no meaning of its own in either engine --
/// both treat it exactly like ⇧-click (Shift wins over Option in Chromium's
/// disposition rules, and WebKitTab.clickDisposition only looks at Shift) --
/// so claiming it takes nothing away. Plain ⇧-click still opens a window and
/// plain ⌥-click still downloads. The context-menu "Peek Link" item is not
/// affected by this setting.
enum LinkPeekPreference {
    private static let key = "BrowserLinkPeekOnOptionShiftClick"

    static var isEnabled: Bool {
        get {
            // AppPreferencesStore.current, not .standard -- see that type's
            // doc comment.
            AppPreferencesStore.current.object(forKey: key) as? Bool ?? true
        }
        set {
            AppPreferencesStore.current.set(newValue, forKey: key)
        }
    }
}
