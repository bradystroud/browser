import AppKit

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
    /// Posted whenever SidebarLayoutPreference's edge or hidden state
    /// changes, for the same every-window-follows reason.
    static let sidebarLayoutPreferenceDidChange = Notification.Name("SidebarLayoutPreferenceDidChange")
}

/// Where the tab strip sits: a horizontal row under the toolbar (the default,
/// unchanged from before this setting existed) or a vertical sidebar down the
/// window's leading edge, Safari/Arc style -- or the sidebar layout, where
/// one full-height sidebar carries the toolbar's controls too and there is no
/// toolbar row at all (see SidebarChrome).
///
/// The sidebar layout is a third case here rather than a separate setting
/// because the three are mutually exclusive answers to one question, where
/// the window's chrome lives: as its own on/off setting it would make
/// "sidebar layout with a horizontal tab strip" expressible, which means
/// nothing. TabStripView itself only ever sees `stripAxis`.
///
/// This is a layout choice, not a rendering detail: the sidebar is a real
/// sibling view that the web content area's frame is shrunk to make room for
/// (see BrowserWindowController.applyChromeLayout), because CEF's own
/// compositing paints over any AppKit view that overlaps the content area
/// regardless of z-order -- see contentAreaTopY's own doc comment.
enum TabStripOrientation: String, CaseIterable {
    case horizontal
    case vertical
    case sidebar

    var title: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .sidebar: return "Sidebar"
        }
    }

    /// What the Settings popup and the View > Tab Layout menu call each
    /// choice.
    var layoutTitle: String {
        switch self {
        case .horizontal: return "Tabs Across the Top"
        case .vertical: return "Tabs Down the Side"
        case .sidebar: return "Sidebar"
        }
    }

    /// The direction TabStripView lays its items out in. The sidebar layout
    /// uses the vertical strip exactly as it is (pinned grid, group folders,
    /// New Tab row); only the chrome around it differs.
    var stripAxis: TabStripOrientation {
        self == .horizontal ? .horizontal : .vertical
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
    /// In the sidebar layout the same chord hides and shows the sidebar
    /// instead: that layout has nowhere else for the tabs to go.
    static func toggle() {
        switch current {
        case .horizontal: current = .vertical
        case .vertical: current = .horizontal
        case .sidebar: SidebarLayoutPreference.isHidden.toggle()
        }
    }

    /// Choosing a layout from Settings or the View menu. Picking the sidebar
    /// layout always shows the sidebar, even if it was hidden the last time
    /// that layout was used -- otherwise the choice would appear to do nothing.
    static func choose(_ layout: TabStripOrientation) {
        if layout == .sidebar, current != .sidebar {
            SidebarLayoutPreference.isHidden = false
        }
        current = layout
    }
}

/// View > Tab Layout: one radio item per layout. Its own target rather than
/// the window controller, because the choice is app-wide and has to work
/// with no browser window key.
final class TabLayoutMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = TabLayoutMenuTarget()

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Tab Layout")
        for layout in TabStripOrientation.allCases {
            let item = NSMenuItem(title: layout.layoutTitle, action: #selector(chooseLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc func chooseLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = TabStripOrientation(rawValue: raw) else { return }
        TabStripOrientationPreference.choose(layout)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseLayout(_:)) {
            let raw = menuItem.representedObject as? String
            menuItem.state = raw == TabStripOrientationPreference.current.rawValue ? .on : .off
        }
        return true
    }
}

/// Which window edge the sidebar layout's sidebar sits on.
enum SidebarEdge: String, CaseIterable {
    case left
    case right

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// The sidebar layout's own settings: which edge it sits on, and whether it
/// is hidden (it then slides back in while the pointer is at that edge -- see
/// SidebarChrome). Global, like TabStripOrientationPreference and for the same
/// reason; hiding it in one window hides it in all of them, so ⌘N never opens
/// a window in the other state.
enum SidebarLayoutPreference {
    private static let edgeKey = "BrowserSidebarLayoutEdge"
    private static let hiddenKey = "BrowserSidebarLayoutHidden"

    static var edge: SidebarEdge {
        get {
            AppPreferencesStore.current.string(forKey: edgeKey).flatMap(SidebarEdge.init(rawValue:)) ?? .left
        }
        set {
            guard newValue != edge else { return }
            AppPreferencesStore.current.set(newValue.rawValue, forKey: edgeKey)
            NotificationCenter.default.post(name: .sidebarLayoutPreferenceDidChange, object: nil)
        }
    }

    static var isHidden: Bool {
        get { AppPreferencesStore.current.bool(forKey: hiddenKey) }
        set {
            guard newValue != isHidden else { return }
            AppPreferencesStore.current.set(newValue, forKey: hiddenKey)
            NotificationCenter.default.post(name: .sidebarLayoutPreferenceDidChange, object: nil)
        }
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
