import AppKit

/// One row in the "Keyboard Shortcuts" overlay: a display-ready key
/// combination and the human-readable action it performs.
struct ShortcutEntry {
    let key: String
    let title: String
}

enum ShortcutCategory: Int, CaseIterable {
    case tabs
    case navigation
    case windowsAndProfiles
    case links
    case general

    var title: String {
        switch self {
        case .tabs: return "Tabs"
        case .navigation: return "Navigation"
        case .windowsAndProfiles: return "Windows & Profiles"
        case .links: return "Links"
        case .general: return "General"
        }
    }
}

/// Builds the overlay's content by reading `NSApp.mainMenu` live each time
/// it's opened, rather than keeping a separate copy of every key/title --
/// that's the "one source of truth" the shortcuts list can't drift from as
/// MainMenuBuilder changes. What's hand-maintained here is only the
/// *inclusion and grouping* (which real menu items are worth surfacing in a
/// cheat sheet, and under which heading) -- a small, low-churn lookup, not a
/// duplicate of the actual keys or titles.
enum ShortcutsHelp {
    private static let categoryBySelector: [Selector: ShortcutCategory] = [
        #selector(BrowserWindowController.newTab(_:)): .tabs,
        #selector(BrowserWindowController.closeTab(_:)): .tabs,
        #selector(BrowserWindowController.selectNextTab(_:)): .tabs,
        #selector(BrowserWindowController.selectPreviousTab(_:)): .tabs,
        #selector(BrowserWindowController.focusOmnibox(_:)): .navigation,
        #selector(BrowserWindowController.reloadPage(_:)): .navigation,
        #selector(BrowserWindowController.goBackAction(_:)): .navigation,
        #selector(BrowserWindowController.goForwardAction(_:)): .navigation,
        #selector(AppDelegate.newWindow(_:)): .windowsAndProfiles,
        #selector(NSWindow.performClose(_:)): .windowsAndProfiles,
        #selector(BrowserWindowController.copyCurrentURL(_:)): .links,
        #selector(BrowserWindowController.showKeyboardShortcuts(_:)): .general,
        #selector(NSApplication.terminate(_:)): .general,
    ]

    /// ⌘1-9 deliberately has no menu item (nine near-identical entries would
    /// be clutter -- see BrowserWindow.performKeyEquivalent), so it's the one
    /// entry not read live from a real menu item.
    private static let extraEntries: [ShortcutCategory: [ShortcutEntry]] = [
        .tabs: [ShortcutEntry(key: "⌘1–9", title: "Select Tab")],
    ]

    static func sections() -> [(ShortcutCategory, [ShortcutEntry])] {
        var entries: [ShortcutCategory: [ShortcutEntry]] = [:]

        if let mainMenu = NSApp.mainMenu {
            for topItem in mainMenu.items {
                guard let submenu = topItem.submenu else { continue }
                for item in submenu.items {
                    guard !item.keyEquivalent.isEmpty, let action = item.action,
                          let category = categoryBySelector[action] else { continue }
                    entries[category, default: []].append(
                        ShortcutEntry(key: displayString(for: item), title: item.title))
                }
            }
        }

        for (category, extra) in extraEntries {
            entries[category, default: []].append(contentsOf: extra)
        }

        return ShortcutCategory.allCases.compactMap { category in
            guard let items = entries[category], !items.isEmpty else { return nil }
            return (category, items)
        }
    }

    private static func displayString(for item: NSMenuItem) -> String {
        var parts = ""
        let mods = item.keyEquivalentModifierMask
        if mods.contains(.control) { parts += "⌃" }
        if mods.contains(.option) { parts += "⌥" }
        if mods.contains(.shift) { parts += "⇧" }
        if mods.contains(.command) { parts += "⌘" }
        switch item.keyEquivalent {
        case "\u{F702}": parts += "←"
        case "\u{F703}": parts += "→"
        default: parts += item.keyEquivalent.uppercased()
        }
        return parts
    }
}
