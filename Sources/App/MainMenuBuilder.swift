import AppKit

/// Builds NSApp.mainMenu in code (this app has no MainMenu.xib). Most items
/// use a nil target so AppKit routes them through the responder chain: tab/
/// navigation actions land on the key window's BrowserWindowController
/// (NSWindowController is automatically the window's next responder),
/// app-wide actions (New Window, Profiles) fall through to AppDelegate.
final class MainMenuBuilder {
    let profilesMenu = NSMenu(title: "Profiles")
    let windowMenu = NSMenu(title: "Window")

    func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(topLevelItem(title: "Browser", submenu: appMenu()))
        main.addItem(topLevelItem(title: "File", submenu: fileMenu()))
        main.addItem(topLevelItem(title: "Edit", submenu: editMenu()))
        main.addItem(topLevelItem(title: "View", submenu: viewMenu()))
        main.addItem(topLevelItem(title: "History", submenu: historyMenu()))
        main.addItem(topLevelItem(title: "Profiles", submenu: profilesMenu))
        main.addItem(topLevelItem(title: "Window", submenu: windowMenu))

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

    private func historyMenu() -> NSMenu {
        let menu = NSMenu(title: "History")
        menu.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "\u{F702}")
        menu.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "\u{F703}")
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
