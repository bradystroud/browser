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
    /// Posted whenever SidebarLayoutPreference.edge changes, for the same
    /// every-window-follows reason.
    static let sidebarLayoutPreferenceDidChange = Notification.Name("SidebarLayoutPreferenceDidChange")
    /// Posted whenever TabsHiddenPreference.isHidden changes, for the same
    /// every-window-follows reason.
    static let tabsHiddenDidChange = Notification.Name("TabsHiddenDidChange")
    /// Posted whenever CompactTabsPreference.isEnabled changes, for the same
    /// every-window-follows reason.
    static let compactTabsDidChange = Notification.Name("CompactTabsDidChange")
    /// Posted whenever VerticalTabsWidthPreference.width changes, for the
    /// same every-window-follows reason.
    static let verticalTabsWidthDidChange = Notification.Name("VerticalTabsWidthDidChange")
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
        case .horizontal: return "Tabs on Top"
        case .vertical: return "Tabs on Side"
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

    /// Choosing a layout from Settings or the View menu. A layout picked
    /// while the tabs are hidden shows them: otherwise the choice would
    /// appear to do nothing, or to take the tabs away.
    static func choose(_ layout: TabStripOrientation) {
        if layout != current { TabsHiddenPreference.isHidden = false }
        current = layout
    }
}

/// View > Tab Layout, one radio item per layout, and View > Hide Sidebar.
/// Its own target rather than the window controller, because both are
/// app-wide and have to work with no browser window key.
///
/// "Sidebar" is the one name for the column at the side of the window in
/// both layouts that have one, whether it holds the tabs alone or the
/// address bar too. No command changes the layout by a shortcut: the layout
/// is a choice made once.
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

    /// ⌘S, as in Arc. validateMenuItem makes it "Show Sidebar" while the
    /// sidebar is hidden.
    func makeHideSidebarItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Hide Sidebar", action: #selector(toggleSidebarHidden(_:)), keyEquivalent: "s")
        item.target = self
        return item
    }

    @objc func chooseLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = TabStripOrientation(rawValue: raw) else { return }
        TabStripOrientationPreference.choose(layout)
    }

    @objc func toggleSidebarHidden(_ sender: Any?) {
        guard TabStripOrientationPreference.current != .horizontal else { return }
        TabsHiddenPreference.isHidden.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let layout = TabStripOrientationPreference.current
        switch menuItem.action {
        case #selector(chooseLayout(_:)):
            let raw = menuItem.representedObject as? String
            menuItem.state = raw == layout.rawValue ? .on : .off
            return true
        case #selector(toggleSidebarHidden(_:)):
            // Tabs on top have no sidebar to hide.
            let isHidden = layout != .horizontal && TabsHiddenPreference.isHidden
            menuItem.title = isHidden ? "Show Sidebar" : "Hide Sidebar"
            return layout != .horizontal
        default:
            return true
        }
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

/// The sidebar layout's own setting: which edge it sits on. Global, like
/// TabStripOrientationPreference and for the same reason.
enum SidebarLayoutPreference {
    private static let edgeKey = "BrowserSidebarLayoutEdge"

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
}

/// Whether the tabs are hidden, in both layouts that keep them in a column
/// ("Tabs on Side" and "Sidebar"): the column goes away, and comes back out
/// while the pointer rests at its edge of the window (SlimTabsChrome,
/// SidebarChrome). One flag for the two layouts, so the one command means
/// the same thing in both and survives a change between them. "Tabs on Top"
/// ignores it. Global, like TabStripOrientationPreference and for the same
/// reason: hiding the tabs in one window hides them in all, so ⌘N never
/// opens a window in the other state.
enum TabsHiddenPreference {
    private static let key = "BrowserTabsHidden"

    static var isHidden: Bool {
        get {
            let store = AppPreferencesStore.current
            if store.object(forKey: key) != nil { return store.bool(forKey: key) }
            return LegacyTabColumnSettings.isHidden
        }
        set {
            guard newValue != isHidden else { return }
            AppPreferencesStore.current.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .tabsHiddenDidChange, object: nil)
        }
    }
}

/// Compact tabs, for the "Tabs on Side" layout only: the column is a narrow
/// strip of favicons that widens to the full list while the pointer is on it
/// (see SlimTabsChrome). Independent of TabsHiddenPreference, which wins
/// while both are on. Global, like TabStripOrientationPreference and for the
/// same reason; it keeps its value while another layout is the choice.
enum CompactTabsPreference {
    private static let key = "BrowserCompactTabs"

    static var isEnabled: Bool {
        get {
            let store = AppPreferencesStore.current
            if store.object(forKey: key) != nil { return store.bool(forKey: key) }
            return LegacyTabColumnSettings.isCompact
        }
        set {
            guard newValue != isEnabled else { return }
            AppPreferencesStore.current.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .compactTabsDidChange, object: nil)
        }
    }
}

/// What TabsHiddenPreference and CompactTabsPreference say until each is
/// first written: the answer the settings they replaced would have given.
/// Those were a three-way value for "Tabs on Side" (full, slim or hidden,
/// with the last shown one of the first two kept beside it), a boolean for
/// slim before that, and a separate hidden flag for the sidebar layout.
private enum LegacyTabColumnSettings {
    private static var store: UserDefaults { AppPreferencesStore.current }
    private static var sidePresentation: String? { store.string(forKey: "BrowserVerticalTabsPresentation") }

    static var isHidden: Bool {
        TabStripOrientationPreference.current == .sidebar
            ? store.bool(forKey: "BrowserSidebarLayoutHidden")
            : sidePresentation == "hidden"
    }

    static var isCompact: Bool {
        switch sidePresentation {
        case "slim": return true
        case "full": return false
        case "hidden": return store.string(forKey: "BrowserVerticalTabsShownPresentation") == "slim"
        default: return store.bool(forKey: "BrowserSlimVerticalTabs")
        }
    }
}

/// How wide the tab column is in the "Tabs on Side" layout: the user
/// drags the column's edge (see TabColumnResizeHandle). It is also how wide
/// a compact or hidden column becomes while the pointer is on it. Global, like
/// TabStripOrientationPreference and for the same reason. The sidebar layout
/// has its own fixed width (SidebarChrome.width).
enum VerticalTabsWidthPreference {
    private static let key = "BrowserVerticalTabsWidth"
    /// Narrower than this a title shows only a few characters, and the
    /// column is better slim.
    static let minimum: CGFloat = 180
    static let maximum: CGFloat = 400
    static let standard = TabStripView.sidebarWidth

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width.rounded(), minimum), maximum)
    }

    static var width: CGFloat {
        get {
            let stored = AppPreferencesStore.current.double(forKey: key)
            return stored > 0 ? clamped(CGFloat(stored)) : standard
        }
        set {
            let value = clamped(newValue)
            guard value != width else { return }
            AppPreferencesStore.current.set(Double(value), forKey: key)
            NotificationCenter.default.post(name: .verticalTabsWidthDidChange, object: nil)
        }
    }
}

/// Settings > General > Always show tab bar. Off (the default), the horizontal strip is
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
}
