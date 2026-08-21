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
        main.addItem(topLevelItem(title: "Developer", submenu: developerMenu()))
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
        // ⌃⌘N -- the keyboard quick-switcher (browser-sdj.2). A real menu
        // item, not just an event monitor, so the shortcut is registered the
        // normal way and is discoverable next to the profiles it switches
        // between. ⌘N (New Window) and ⇧⌘N (New Private Window) are taken;
        // ⌃⌘N is free across this menu bar and the app's event monitors.
        profilesMenu.addItem(withTitle: "Switch Profile…", action: #selector(AppDelegate.showProfileSwitcher(_:)), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .control]
        profilesMenu.addItem(.separator())
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
        // Explicit target rather than the responder chain every other item
        // here uses: UpdateCoordinator is the one that knows whether this
        // launch has a live updater at all, and it greys the item out
        // (NSMenuItemValidation) when it does not -- see browser-wc7.
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdateCoordinator.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = UpdateCoordinator.shared
        menu.addItem(checkForUpdatesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        // Directly under Settings…, where Safari puts its own equivalent, and
        // reading as "settings, but narrower". The chord is ours -- Safari
        // assigns none -- and was checked against every other equivalent in
        // this file before being taken (browser-06d).
        //
        // Explicitly targeted at the controller singleton rather than left to
        // the responder chain: that keeps the action off AppDelegate and off
        // every window, and lets the controller's own NSMenuItemValidation
        // grey the item out on a page it can't describe (the start page, a
        // view-source: tab), instead of offering a sheet that would open empty.
        let siteSettingsItem = menu.addItem(
            withTitle: "Settings for This Website…",
            action: #selector(SiteSettingsSheetController.showFromMenu(_:)),
            keyEquivalent: ","
        )
        siteSettingsItem.keyEquivalentModifierMask = [.command, .option]
        siteSettingsItem.target = SiteSettingsSheetController.shared
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
        menu.addItem(withTitle: "New Private Window", action: #selector(AppDelegate.newPrivateWindow(_:)), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .shift]
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
        menu.addItem(.separator())
        // Targets BrowserWindow (the NSWindow itself, ahead of its
        // NSWindowController in the responder chain), not
        // BrowserWindowController -- see that file's own doc comment on
        // -printPage:/-exportAsPDF: for why (browser-5kq.6).
        menu.addItem(withTitle: "Export as PDF…", action: #selector(BrowserWindow.exportAsPDF(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Print…", action: #selector(BrowserWindow.printPage(_:)), keyEquivalent: "p")
        menu.addItem(.separator())
        // Explicit targets (BookmarkImportCoordinator.shared), not the nil-
        // target/responder-chain pattern most of this menu uses -- import
        // is a standalone singleton coordinator, like RoutingCoordinator/
        // ContentBlockerCoordinator, precisely so this doesn't need to add
        // any surface area to AppDelegate (browser-ymx).
        let importFileItem = NSMenuItem(
            title: "Import Bookmarks…",
            action: #selector(BookmarkImportCoordinator.importFromFile(_:)),
            keyEquivalent: ""
        )
        importFileItem.target = BookmarkImportCoordinator.shared
        menu.addItem(importFileItem)

        let importSafariItem = NSMenuItem(
            title: "Import Bookmarks from Safari…",
            action: #selector(BookmarkImportCoordinator.importFromSafari(_:)),
            keyEquivalent: ""
        )
        importSafariItem.target = BookmarkImportCoordinator.shared
        menu.addItem(importSafariItem)

        // The bigger browser-ymx flow (profiles + favourites + history, a
        // real window rather than a one-shot menu action) -- a separate
        // entry point from the two plain-bookmarks ones above, which keep
        // working exactly as they did before this was added.
        let importFullSafariItem = NSMenuItem(
            title: "Import from Safari…",
            action: #selector(SafariImportWindowController.show(_:)),
            keyEquivalent: ""
        )
        importFullSafariItem.target = SafariImportWindowController.shared
        menu.addItem(importFullSafariItem)
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
        menu.addItem(.separator())
        // Targets BrowserWindow (the NSWindow itself), not
        // BrowserWindowController -- see BrowserWindow.toggleFindBar:'s own
        // doc comment for why (browser-5kq.5).
        menu.addItem(withTitle: "Find…", action: #selector(BrowserWindow.toggleFindBar(_:)), keyEquivalent: "f")
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        menu.addItem(withTitle: "Show Address Bar", action: #selector(BrowserWindowController.focusOmnibox(_:)), keyEquivalent: "l")
        menu.addItem(.separator())
        appendZoomItems(to: menu)
        menu.addItem(.separator())
        // Targets BrowserWindow (the NSWindow itself), not
        // BrowserWindowController -- see BrowserWindow.toggleReaderMode:'s
        // own doc comment for why (browser-5kq.1).
        menu.addItem(withTitle: "Show Reader", action: #selector(BrowserWindow.toggleReaderMode(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .shift]
        let fontSizeItem = NSMenuItem(title: "Reader Text Size", action: nil, keyEquivalent: "")
        fontSizeItem.submenu = readerFontSizeMenu()
        menu.addItem(fontSizeItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tab Overview", action: #selector(BrowserWindowController.showTabOverview(_:)), keyEquivalent: "\\")
            .keyEquivalentModifierMask = [.command, .shift]
        // Vertical tab sidebar (browser-vts). The title is a STARTING value,
        // not a fixed one: BrowserWindowController.validateMenuItem flips it to
        // "Hide Tab Sidebar" while the sidebar is showing, the same way Pin
        // Tab/Unpin Tab already does.
        //
        // Ctrl-Cmd-S: Safari ships no default chord for its own sidebar toggle,
        // so there is nothing to match here. Cmd-S is free in this app but
        // reads as "Save" to everyone; Shift-Cmd-L is Safari's *old*
        // bookmark-sidebar chord and Cmd-L is already Show Address Bar here, so
        // a shifted sibling would invite mistakes. Ctrl-Cmd is this app's
        // established chrome-layout modifier -- Switch Profile uses Ctrl-Cmd-N.
        menu.addItem(
            withTitle: "Show Tab Sidebar",
            action: #selector(BrowserWindowController.toggleTabSidebar(_:)),
            keyEquivalent: "s"
        ).keyEquivalentModifierMask = [.command, .control]
        menu.addItem(.separator())
        let responsiveItem = NSMenuItem(title: "Responsive Design Mode", action: nil, keyEquivalent: "")
        responsiveItem.submenu = responsiveDesignModeMenu()
        menu.addItem(responsiveItem)
        menu.addItem(.separator())
        // browser-7jz.1 -- targets AppDelegate (not BrowserWindowController),
        // matching the Responsive Design Mode item just above.
        menu.addItem(withTitle: "Enter Picture in Picture", action: #selector(AppDelegate.togglePictureInPicture(_:)), keyEquivalent: "")
        return menu
    }

    /// Zoom In / Zoom Out / Actual Size (browser-5kq.15).
    ///
    /// Zoom In carries "+" rather than "=", so the menu reads "⌘+" -- the
    /// shortcut people are looking for -- rather than the
    /// literally-accurate-but-wrong-looking "⌘=". A key equivalent is matched
    /// against the event's charactersIgnoringModifiers, which applies Shift, so
    /// this item alone covers ⌘⇧= and nothing else.
    ///
    /// The *other* half of "⌘+" -- plain, unshifted ⌘=, which is what most
    /// people actually press -- cannot be expressed as a menu item alongside
    /// this one and is handled in BrowserWindow.performKeyEquivalent(with:)
    /// instead, next to ⌘1-9. See that method for why a hidden second menu item
    /// carrying "=" is not a working alternative (it was tried and shipped
    /// broken), and for how the two paths stay mutually exclusive.
    private func appendZoomItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "+")
        menu.addItem(withTitle: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: #selector(BrowserWindowController.actualSize(_:)), keyEquivalent: "0")
    }

    /// browser-6hi.2 -- a fixed device-preset list plus "Off", each
    /// targeting AppDelegate.setResponsiveDesignMode(_:)/
    /// clearResponsiveDesignMode(_:) (not BrowserWindowController -- see
    /// those methods' own doc comments for why the active-tab lookup lives
    /// there instead). No "Custom Size…" entry (yet): the fixed presets
    /// cover the common case simply; a custom-size prompt is a
    /// straightforward follow-up if ever asked for.
    private func responsiveDesignModeMenu() -> NSMenu {
        let menu = NSMenu(title: "Responsive Design Mode")
        for preset in ResponsiveDevicePreset.all {
            let item = NSMenuItem(title: preset.name, action: #selector(AppDelegate.setResponsiveDesignMode(_:)), keyEquivalent: "")
            item.representedObject = preset
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Off", action: #selector(AppDelegate.clearResponsiveDesignMode(_:)), keyEquivalent: "")
        return menu
    }

    private func readerFontSizeMenu() -> NSMenu {
        let menu = NSMenu(title: "Reader Text Size")
        menu.addItem(withTitle: ReaderFontSize.small.title, action: #selector(BrowserWindow.setReaderFontSizeSmall(_:)), keyEquivalent: "")
        menu.addItem(withTitle: ReaderFontSize.medium.title, action: #selector(BrowserWindow.setReaderFontSizeMedium(_:)), keyEquivalent: "")
        menu.addItem(withTitle: ReaderFontSize.large.title, action: #selector(BrowserWindow.setReaderFontSizeLarge(_:)), keyEquivalent: "")
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
        // No-popover, one-click discoverable route to Favorites (browser-
        // 5kq.7) -- complements "Add Bookmark" above, which opens a picker
        // defaulting to Favorites but lets you choose otherwise.
        bookmarksMenu.addItem(withTitle: "Add to Favourites", action: #selector(BrowserWindowController.addActiveTabToFavorites(_:)), keyEquivalent: "")
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
                if children.isEmpty {
                    // An empty submenu renders as a folder item that opens
                    // onto literally nothing -- indistinguishable from the
                    // menu being broken (this is exactly what the "Favorites"
                    // folder looks like before a user has filed anything into
                    // it, since FavoritesFolder auto-creates it empty the
                    // first time the start page renders). A disabled
                    // placeholder makes the empty state visible instead of
                    // silent.
                    let empty = NSMenuItem(
                        title: item.title == FavoritesFolder.title ? "No favourites yet" : "No bookmarks",
                        action: nil,
                        keyEquivalent: ""
                    )
                    empty.isEnabled = false
                    submenu.addItem(empty)
                } else {
                    for child in children {
                        switch child.kind {
                        case .bookmark:
                            let childItem = NSMenuItem(title: child.title, action: #selector(AppDelegate.openMenuURL(_:)), keyEquivalent: "")
                            childItem.representedObject = child.url
                            submenu.addItem(childItem)
                        case .folder:
                            // One level of nesting only -- see this method's
                            // doc comment; a nested subfolder shows as a
                            // prompt into the full manager instead of
                            // recursing indefinitely.
                            let placeholder = NSMenuItem(
                                title: "\(child.title) (open in Bookmarks manager)",
                                action: #selector(BrowserWindowController.showBookmarksManager(_:)),
                                keyEquivalent: ""
                            )
                            submenu.addItem(placeholder)
                        }
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

    /// "JavaScript Console" aliases the same action as "Open Developer
    /// Tools" for now (browser-6hi.1) -- CEF's ShowDevTools always opens the
    /// full inspector, there's no separate console-only entry point to
    /// route to instead. Placement matches Safari's own top-level "Develop"
    /// menu (History, Bookmarks, Develop, then Window/Help).
    private func developerMenu() -> NSMenu {
        let menu = NSMenu(title: "Developer")
        menu.addItem(withTitle: "Open Developer Tools", action: #selector(BrowserWindowController.showDevTools(_:)), keyEquivalent: "i")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "JavaScript Console", action: #selector(BrowserWindowController.showDevTools(_:)), keyEquivalent: "j")
            .keyEquivalentModifierMask = [.command, .option]
        return menu
    }

    private func buildWindowMenuStaticItems() {
        windowMenu.addItem(withTitle: "Select Next Tab", action: #selector(BrowserWindowController.selectNextTab(_:)), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Select Previous Tab", action: #selector(BrowserWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        // ⌥⌘P, not plain ⌘P (Print) -- Safari itself has no pin shortcut
        // (context-menu only), so this doesn't need to match anything, just
        // avoid colliding with Print. Title toggles between "Pin Tab"/
        // "Unpin Tab" in BrowserWindowController.validateMenuItem(_:).
        windowMenu.addItem(withTitle: "Pin Tab", action: #selector(BrowserWindowController.togglePinActiveTab(_:)), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
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
