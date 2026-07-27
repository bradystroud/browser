import AppKit

/// Builds NSApp.mainMenu in code (this app has no MainMenu.xib). Most items
/// use a nil target so AppKit routes them through the responder chain: tab/
/// navigation actions land on the key window's BrowserWindowController
/// (NSWindowController is automatically the window's next responder),
/// app-wide actions (New Window, Profiles) fall through to AppDelegate.
final class MainMenuBuilder {
    let profilesMenu = NSMenu(title: "Profiles")
    let windowMenu = NSMenu(title: "Window")
    let historyMenu = NSMenu(title: "History")
    let bookmarksMenu = NSMenu(title: "Bookmarks")

    /// Item counts captured right after each menu's static items are built,
    /// so rebuildRecentHistory(for:)/rebuildBookmarksMenu(for:) know how many
    /// trailing items are their own dynamic content to clear before
    /// repopulating -- simpler than scanning for a sentinel separator.
    private var historyMenuStaticCount = 0
    private var bookmarksMenuStaticCount = 0

    /// Keeps the Profiles menu in sync with ProfileManager regardless of
    /// which UI surface made the change (this menu's own "New Profile…",
    /// or the Settings window's Profiles pane create/rename/recolor/delete)
    /// -- decouples menu upkeep from every call site that mutates profiles,
    /// rather than requiring each one to remember to call
    /// rebuildProfilesMenu() itself.
    private var profileChangeObserver: NSObjectProtocol?

    init() {
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildProfilesMenu()
        }
    }

    func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(topLevelItem(title: "Browser", submenu: appMenu()))
        main.addItem(topLevelItem(title: "File", submenu: fileMenu()))
        main.addItem(topLevelItem(title: "Edit", submenu: editMenu()))
        main.addItem(topLevelItem(title: "View", submenu: viewMenu()))
        main.addItem(topLevelItem(title: "History", submenu: historyMenu))
        main.addItem(topLevelItem(title: "Bookmarks", submenu: bookmarksMenu))
        main.addItem(topLevelItem(title: "Profiles", submenu: profilesMenu))
        main.addItem(topLevelItem(title: "Window", submenu: windowMenu))
        main.addItem(topLevelItem(title: "Help", submenu: helpMenu()))

        buildHistoryMenuStaticItems()
        buildBookmarksMenuStaticItems()
        buildWindowMenuStaticItems()
        rebuildProfilesMenu()
        return main
    }

    /// Called after ProfileManager gains a new profile so the menu reflects
    /// it without rebuilding the whole menu bar.
    func rebuildProfilesMenu() {
        profilesMenu.removeAllItems()
        for profile in ProfileManager.shared.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.openProfileWindow(_:)), keyEquivalent: "")
            item.representedObject = profile
            item.image = colorDotImage(hex: profile.colorHex)
            profilesMenu.addItem(item)
        }
        profilesMenu.addItem(.separator())
        profilesMenu.addItem(withTitle: "New Profile…", action: #selector(AppDelegate.newProfilePrompt(_:)), keyEquivalent: "")
    }

    private func topLevelItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        item.submenu = submenu
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Browser")
        menu.addItem(withTitle: "About Browser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Browser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeTab(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Current Page URL", action: #selector(BrowserWindowController.copyCurrentURL(_:)), keyEquivalent: "c")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Downloads…", action: #selector(BrowserWindowController.showDownloads(_:)), keyEquivalent: "j")
            .keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        menu.addItem(withTitle: "Show Address Bar", action: #selector(BrowserWindowController.focusOmnibox(_:)), keyEquivalent: "l")
        return menu
    }

    /// Back/Forward/"Show All History…" are static; everything after them is
    /// a live-rebuilt list of the key window's profile's recent history --
    /// see rebuildRecentHistory(for:), called from AppDelegate whenever the
    /// key window changes or a new visit is recorded.
    private func buildHistoryMenuStaticItems() {
        historyMenu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "\u{F702}")
        historyMenu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "\u{F703}")
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Show All History…", action: #selector(BrowserWindowController.showHistory(_:)), keyEquivalent: "y")
        historyMenuStaticCount = historyMenu.items.count
    }

    /// Rebuilds the History menu's recent-items section for `profile` --
    /// safe to call often (e.g. after every recorded visit in the key
    /// window); ten items is cheap to regenerate from HistoryStore each time
    /// rather than tracking incremental deltas.
    func rebuildRecentHistory(for profile: Profile) {
        while historyMenu.items.count > historyMenuStaticCount {
            historyMenu.removeItem(at: historyMenu.items.count - 1)
        }
        let entries = (try? ProfileDataStoreManager.shared.stores(for: profile).history.entries(limit: 10)) ?? []
        guard !entries.isEmpty else { return }
        historyMenu.addItem(.separator())
        for entry in entries {
            let item = NSMenuItem(
                title: entry.title.isEmpty ? entry.url : entry.title,
                action: #selector(AppDelegate.openMenuURL(_:)),
                keyEquivalent: ""
            )
            item.representedObject = entry.url
            historyMenu.addItem(item)
        }
    }

    /// "Add Bookmark"/"Show All Bookmarks…" are static; everything after is
    /// a live-rebuilt one-level-deep bookmark tree for the key window's
    /// profile -- deeper folder nesting is only reachable via the Bookmarks
    /// manager window (see docs/ai-tasks/m3-furniture-notes.md).
    private func buildBookmarksMenuStaticItems() {
        bookmarksMenu.addItem(withTitle: "Add Bookmark", action: #selector(BrowserWindowController.addBookmark(_:)), keyEquivalent: "d")
        bookmarksMenu.addItem(withTitle: "Show All Bookmarks…", action: #selector(BrowserWindowController.showBookmarksManager(_:)), keyEquivalent: "")
        bookmarksMenuStaticCount = bookmarksMenu.items.count
    }

    /// Rebuilds the Bookmarks menu's dynamic section for `profile`.
    func rebuildBookmarksMenu(for profile: Profile) {
        while bookmarksMenu.items.count > bookmarksMenuStaticCount {
            bookmarksMenu.removeItem(at: bookmarksMenu.items.count - 1)
        }
        let store = ProfileDataStoreManager.shared.stores(for: profile).bookmarks
        let topLevel = (try? store.children(of: nil)) ?? []
        guard !topLevel.isEmpty else { return }
        bookmarksMenu.addItem(.separator())
        appendBookmarkItems(topLevel, to: bookmarksMenu, store: store)
    }

    private func appendBookmarkItems(_ items: [BookmarkItem], to menu: NSMenu, store: BookmarkStore) {
        for item in items {
            switch item.kind {
            case .bookmark:
                let menuItem = NSMenuItem(title: item.title, action: #selector(AppDelegate.openMenuURL(_:)), keyEquivalent: "")
                menuItem.representedObject = item.url
                menu.addItem(menuItem)
            case .folder:
                let submenu = NSMenu(title: item.title)
                let children = (try? store.children(of: item.id)) ?? []
                for child in children {
                    switch child.kind {
                    case .bookmark:
                        let childItem = NSMenuItem(title: child.title, action: #selector(AppDelegate.openMenuURL(_:)), keyEquivalent: "")
                        childItem.representedObject = child.url
                        submenu.addItem(childItem)
                    case .folder:
                        // One level of nesting only -- see this method's doc
                        // comment; a nested subfolder shows as a prompt into
                        // the full manager instead of recursing indefinitely.
                        let placeholder = NSMenuItem(
                            title: "\(child.title) (open in Bookmarks manager)",
                            action: #selector(BrowserWindowController.showBookmarksManager(_:)),
                            keyEquivalent: ""
                        )
                        submenu.addItem(placeholder)
                    }
                }
                let folderItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                folderItem.submenu = submenu
                menu.addItem(folderItem)
            }
        }
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        // Default keyEquivalentModifierMask for a plain key is .command, so
        // this is Cmd+/ -- bare "?" is handled separately by
        // ShortcutsOverlayController, which also gates it to native-chrome
        // focus (Cmd-modified keys never type as characters, so this one
        // needs no such gating).
        menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(BrowserWindowController.showKeyboardShortcuts(_:)), keyEquivalent: "/")
        return menu
    }

    private func buildWindowMenuStaticItems() {
        windowMenu.addItem(withTitle: "Select Next Tab", action: #selector(BrowserWindowController.selectNextTab(_:)), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Select Previous Tab", action: #selector(BrowserWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }

    private func colorDotImage(hex: String, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        (NSColor(hex: hex) ?? .controlAccentColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        return image
    }
}
