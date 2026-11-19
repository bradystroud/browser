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

/// Where a window's chrome lives. The user chooses between two layouts,
/// "Tabs on Top" and "Sidebar" (TabLayout), and for the sidebar where the
/// address bar goes (SidebarAddressBar); the three cases here are those
/// choices as the one value that is stored and that the window lays out
/// from:
///
/// - horizontal: a row of tabs under the toolbar.
/// - vertical: the sidebar holds the tabs alone, and the toolbar row, with
///   the address bar, runs above the page.
/// - sidebar: the sidebar holds the address bar and every toolbar control
///   too, and there is no toolbar row (see SidebarChrome).
///
/// One stored value rather than a layout and an address-bar setting side by
/// side, because the three are exclusive answers to one question: two
/// values would make "address bar in the sidebar, tabs on top" expressible,
/// which means nothing. TabStripView itself only ever sees `stripAxis`.
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

    static var layout: TabLayout { current == .horizontal ? .top : .sidebar }

    /// Choosing a layout from Settings or the View menu. A layout picked
    /// while the sidebar is hidden shows it: otherwise the choice would
    /// appear to do nothing, or to take the tabs away. The sidebar comes
    /// back with the address bar where it last was.
    static func choose(_ layout: TabLayout) {
        guard layout != self.layout else { return }
        TabsHiddenPreference.isHidden = false
        switch layout {
        case .top:
            AppPreferencesStore.current.set(addressBar.rawValue, forKey: addressBarKey)
            current = .horizontal
        case .sidebar:
            current = addressBar.orientation
        }
    }

    private static let addressBarKey = "BrowserSidebarAddressBar"

    /// Where the sidebar layout keeps the address bar. While that layout is
    /// the choice, the stored orientation is the answer; the separate key
    /// only remembers it across a spell of "Tabs on Top".
    static var addressBar: SidebarAddressBar {
        get {
            switch current {
            case .vertical: return .abovePage
            case .sidebar: return .inSidebar
            case .horizontal:
                return AppPreferencesStore.current.string(forKey: addressBarKey)
                    .flatMap(SidebarAddressBar.init(rawValue:)) ?? .inSidebar
            }
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: addressBarKey)
            if current != .horizontal { current = newValue.orientation }
        }
    }
}

/// The two layouts the user chooses between.
enum TabLayout: CaseIterable {
    case top
    case sidebar

    var title: String {
        switch self {
        case .top: return "Tabs on Top"
        case .sidebar: return "Sidebar"
        }
    }
}

/// Where the sidebar layout keeps the address bar and the toolbar's
/// controls: in the sidebar itself, above the tabs, or in a toolbar row
/// above the page, which leaves the sidebar the tabs alone.
enum SidebarAddressBar: String, CaseIterable {
    case inSidebar
    case abovePage

    var title: String {
        switch self {
        case .inSidebar: return "In Sidebar"
        case .abovePage: return "Above Page"
        }
    }

    var orientation: TabStripOrientation {
        switch self {
        case .inSidebar: return .sidebar
        case .abovePage: return .vertical
        }
    }
}

/// View > Tab Layout, one radio item per layout, and View > Hide Sidebar.
/// Its own target rather than the window controller, because both are
/// app-wide and have to work with no browser window key.
///
/// "Sidebar" is the one name for the column at the side of the window,
/// whether it holds the tabs alone or the address bar too. No command changes the layout by a shortcut: the layout
/// is a choice made once.
final class TabLayoutMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = TabLayoutMenuTarget()

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Tab Layout")
        for (index, layout) in TabLayout.allCases.enumerated() {
            let item = NSMenuItem(title: layout.title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
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
        guard TabLayout.allCases.indices.contains(sender.tag) else { return }
        TabStripOrientationPreference.choose(TabLayout.allCases[sender.tag])
    }

    @objc func toggleSidebarHidden(_ sender: Any?) {
        guard TabStripOrientationPreference.current != .horizontal else { return }
        TabsHiddenPreference.isHidden.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let layout = TabStripOrientationPreference.current
        switch menuItem.action {
        case #selector(chooseLayout(_:)):
            let chosen = TabLayout.allCases.firstIndex(of: TabStripOrientationPreference.layout)
            menuItem.state = menuItem.tag == chosen ? .on : .off
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

/// Whether the sidebar is hidden: it goes away, and comes back out while the
/// pointer rests at its edge of the window (SlimTabsChrome, SidebarChrome).
/// One flag wherever the address bar is, so the one command means the same
/// thing in both arrangements and survives a change between them. "Tabs on Top"
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

/// A compact sidebar: a narrow strip of favicons that widens to the full list while the pointer is on it
/// (see SlimTabsChrome). Only for a sidebar that holds the tabs alone
/// (SidebarAddressBar.abovePage): an address bar cannot be narrowed to an
/// icon. Independent of TabsHiddenPreference, which wins while both are on. Global, like TabStripOrientationPreference and for the
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
/// Those were a three-way value for the `vertical` orientation (full, slim
/// or hidden, with the last shown one of the first two kept beside it), a
/// boolean for slim before that, and a separate hidden flag for the
/// `sidebar` orientation.
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

/// How wide the sidebar is, wherever the address bar is: the user drags the
/// sidebar's edge (see TabColumnResizeHandle). It is also how wide a compact
/// or hidden sidebar becomes while the pointer is on it. Global, like
/// TabStripOrientationPreference and for the same reason.
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
