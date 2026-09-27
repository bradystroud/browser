import AppKit
import WebKit

/// The WKWebView every WebKitTab draws with. Its only addition is a hook on
/// the context menu about to open, which is the one place macOS WebKit lets
/// an app add items of its own.
final class WebKitContentView: WKWebView {
    var onWillOpenMenu: ((NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        onWillOpenMenu?(menu)
    }
}

/// "Peek Link" in WebKit's own context menu.
///
/// WebKit tells an app nothing about what was right-clicked, so the item
/// borrows its link from WebKit's own "Open Link in New Window": choosing
/// Peek Link arms the tab and then performs that item, and the new-window
/// request it produces (WKUIDelegate's createWebViewWith) is turned into a
/// peek instead of a window. Its presence is also how a link is recognized
/// at all. Should a future WebKit rename that item, Peek Link simply stops
/// appearing; nothing else changes.
enum WebKitLinkPeekMenu {
    static let openLinkInNewWindowIdentifier = "WKMenuItemIdentifierOpenLinkInNewWindow"
    static let peekItemTitle = "Peek Link"

    /// How long an armed tab waits for WebKit's new-window request, which
    /// arrives after a round trip through the web content process. Short,
    /// because a stale arming must never turn some later, page-initiated
    /// window into a peek.
    static let armingLifetime: TimeInterval = 2

    /// Inserts Peek Link directly above WebKit's "Open Link in New Window",
    /// carrying that item as its representedObject. Returns the new item, or
    /// nil when the menu is not a link's (or already has one).
    @discardableResult
    static func insertPeekItem(into menu: NSMenu, target: AnyObject, action: Selector) -> NSMenuItem? {
        guard !menu.items.contains(where: { $0.title == peekItemTitle }),
              let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == openLinkInNewWindowIdentifier })
        else { return nil }
        let item = NSMenuItem(title: peekItemTitle, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = menu.items[index]
        menu.insertItem(item, at: index)
        return item
    }

    static func isArmed(since armedAt: Date?, now: Date = Date()) -> Bool {
        guard let armedAt else { return false }
        let age = now.timeIntervalSince(armedAt)
        return age >= 0 && age <= armingLifetime
    }
}

extension WebKitTab {
    func installLinkPeekMenu() {
        (webView as? WebKitContentView)?.onWillOpenMenu = { [weak self] menu in
            guard let self else { return }
            WebKitLinkPeekMenu.insertPeekItem(into: menu, target: self, action: #selector(self.peekLinkMenuItemChosen(_:)))
        }
    }

    @objc func peekLinkMenuItemChosen(_ sender: NSMenuItem) {
        guard let openInNewWindow = sender.representedObject as? NSMenuItem,
              let action = openInNewWindow.action else { return }
        linkPeekMenuArmedAt = Date()
        NSApp.sendAction(action, to: openInNewWindow.target, from: openInNewWindow)
    }

    /// True exactly once for the new-window request Peek Link caused.
    func consumeLinkPeekMenuArming() -> Bool {
        defer { linkPeekMenuArmedAt = nil }
        return WebKitLinkPeekMenu.isArmed(since: linkPeekMenuArmedAt)
    }
}
