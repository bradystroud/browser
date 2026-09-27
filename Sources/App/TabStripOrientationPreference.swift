import Foundation

extension Notification.Name {
    /// Posted whenever TabStripOrientationPreference.current changes, so every
    /// open window relays out its own chrome immediately rather than only the
    /// one whose menu item was clicked -- same "post on change, any window
    /// observes" shape as .omniboxDisplayPreferenceDidChange (see
    /// OmniboxDisplayPreference.swift).
    static let tabStripOrientationDidChange = Notification.Name("TabStripOrientationDidChange")
    /// Posted whenever AlwaysShowTabBarPreference.isEnabled changes, for the
    /// same every-window-follows reason.
    static let alwaysShowTabBarDidChange = Notification.Name("AlwaysShowTabBarDidChange")
}

/// Where the tab strip sits: a horizontal row under the toolbar (the default,
/// unchanged from before this setting existed) or a vertical sidebar down the
/// window's leading edge, Safari/Arc style.
///
/// This is a layout choice, not a rendering detail: the sidebar is a real
/// sibling view that the web content area's frame is shrunk to make room for
/// (see BrowserWindowController.applyChromeLayout), because CEF's own
/// compositing paints over any AppKit view that overlaps the content area
/// regardless of z-order -- see contentAreaTopY's own doc comment.
enum TabStripOrientation: String, CaseIterable {
    case horizontal
    case vertical

    var title: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        }
    }
}

/// Persisted globally rather than per-profile, matching
/// OmniboxDisplayPreference's own reasoning: which way the tabs run is a
/// personal habit about the window's shape, not a property of the identity
/// you happen to be browsing as. It also has to be answerable before any
/// profile is resolved, because it decides the chrome layout of the very
/// first window a launch opens.
enum TabStripOrientationPreference {
    private static let key = "BrowserTabStripOrientation"

    static var current: TabStripOrientation {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- see that type's own doc comment for why.
            guard let raw = AppPreferencesStore.current.string(forKey: key),
                  let orientation = TabStripOrientation(rawValue: raw) else {
                return .horizontal
            }
            return orientation
        }
        set {
            guard newValue != current else { return }
            AppPreferencesStore.current.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .tabStripOrientationDidChange, object: nil)
        }
    }

    /// What the View menu item drives. Kept here rather than in the window
    /// controller so every window ends up in the same mode: the controllers
    /// all react to the notification above, and none of them owns the value.
    static func toggle() {
        current = current == .vertical ? .horizontal : .vertical
    }
}

/// View > Always Show Tab Bar. Off (the default), the horizontal strip is
/// hidden while a window has a single tab, Safari-style, and the web content
/// moves up under the toolbar; on, it shows regardless of tab count. Has no
/// effect on the vertical sidebar. Global rather than per-profile for the
/// same reason as TabStripOrientationPreference.
enum AlwaysShowTabBarPreference {
    private static let key = "BrowserAlwaysShowTabBar"

    static var isEnabled: Bool {
        get { AppPreferencesStore.current.bool(forKey: key) }
        set {
            guard newValue != isEnabled else { return }
            AppPreferencesStore.current.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .alwaysShowTabBarDidChange, object: nil)
        }
    }

    static func toggle() {
        isEnabled.toggle()
    }
}
