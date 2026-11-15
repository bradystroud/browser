import AppKit

/// The toolbar's extensions (puzzle) button and the pinned extensions beside
/// it, one per window -- owned by BrowserWindow like the downloads button,
/// and laid out on the same trailing row
/// (BrowserWindowController.placeTrailingToolbarControl). The puzzle button
/// lists every running extension and pins or unpins them; a pinned one gets
/// a button of its own, showing its icon and badge. Pressing either shows
/// the extension's popup, hanging from the button pressed.
///
/// Nothing is shown in a private window, or on an engine without extensions.
final class ExtensionsToolbarController: NSObject {
    /// Slot 4 on the trailing grid, left of Reader, Downloads and the two
    /// autofill buttons; pinned extensions follow at 5, 6, ...
    private static let firstSlot = 4

    private weak var window: BrowserWindow?
    private var puzzleButton: NSButton?
    private var pinnedButtons: [String: NSButton] = [:]
    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(to window: BrowserWindow) {
        self.window = window
        guard Engines.anyEngine(\.webExtensions) else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .browserExtensionsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? String) == self.controller?.profile.id else { return }
            self.refresh()
        })
        TabLifecycleCenter.shared.addObserver(self)
        // The window controller is attached after this window is built.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private var controller: BrowserWindowController? { window?.windowController as? BrowserWindowController }

    func anchor(forExtension id: String) -> NSView? {
        if let pinned = pinnedButtons[id], !pinned.isHidden, pinned.window != nil { return pinned }
        return puzzleButton
    }

    // MARK: - Layout

    func refresh() {
        guard let window, let contentView = window.contentView, let controller,
              let manager = ExtensionsCoordinator.shared.manager, controller.runsExtensions
        else {
            puzzleButton?.isHidden = true
            pinnedButtons.values.forEach { $0.removeFromSuperview() }
            pinnedButtons = [:]
            return
        }
        let profileId = controller.profile.id
        let puzzle = puzzleButton ?? makePuzzleButton(in: contentView)
        puzzle.isHidden = false
        controller.placeTrailingToolbarControl(puzzle, slot: Self.firstSlot)

        let activeTab = controller.activeTab.map { ExtensionsCoordinator.shared.tabHandle(for: $0, in: controller) }
        let pinned = manager.extensions(profileId: profileId).filter {
            $0.isPinned && Self.showsPinnedButton($0, manager: manager, profileId: profileId, tab: activeTab)
        }
        let pinnedIds = Set(pinned.map(\.id))
        for (id, button) in pinnedButtons where !pinnedIds.contains(id) {
            button.removeFromSuperview()
            pinnedButtons[id] = nil
        }
        for (offset, summary) in pinned.enumerated() {
            let button = pinnedButtons[summary.id] ?? makePinnedButton(id: summary.id, in: contentView)
            controller.placeTrailingToolbarControl(button, slot: Self.firstSlot + 1 + offset)
            let action = manager.action(extensionId: summary.id, profileId: profileId, tab: activeTab)
            button.image = Self.iconImage(action?.icon ?? summary.icon, name: summary.name)
            button.toolTip = Self.toolTip(label: action?.label ?? summary.name, action: action)
            button.alphaValue = (action?.isEnabled ?? true) ? 1 : 0.45
            (button as? ExtensionToolbarButton)?.badgeText = action?.badgeText ?? ""
            button.menu = contextMenu(for: summary)
        }
    }

    private func makePuzzleButton(in contentView: NSView) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")!,
            target: self, action: #selector(puzzleTapped(_:)))
        button.applyChromeAppearance(.glass)
        button.toolTip = "Extensions"
        button.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(button)
        puzzleButton = button
        return button
    }

    private func makePinnedButton(id: String, in contentView: NSView) -> NSButton {
        let button = ExtensionToolbarButton(image: NSImage(), target: self, action: #selector(pinnedTapped(_:)))
        button.extensionId = id
        button.applyChromeAppearance(.glass)
        button.imageScaling = .scaleProportionallyDown
        button.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(button)
        pinnedButtons[id] = button
        return button
    }

    /// An extension with no icon shows its initial rather than a puzzle
    /// piece that would pass for the extensions button itself.
    private static func iconImage(_ icon: NSImage?, name: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        if let icon {
            let copy = icon.copy() as! NSImage
            copy.size = size
            return copy
        }
        let initial = String(name.first.map { String($0) } ?? "?").uppercased()
        return NSImage(size: size, flipped: false) { rect in
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let text = initial as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            return true
        }
    }

    // MARK: - Actions

    @objc private func pinnedTapped(_ sender: ExtensionToolbarButton) {
        guard let id = sender.extensionId else { return }
        if let controller, let manager = ExtensionsCoordinator.shared.manager,
           let reason = Self.disabledReason(manager.action(
               extensionId: id, profileId: controller.profile.id,
               tab: controller.activeTab.map { ExtensionsCoordinator.shared.tabHandle(for: $0, in: controller) })) {
            showReason(reason, from: sender)
            return
        }
        press(id)
    }

    /// Listed in the extensions menu over `tab` (ExtensionToolbarRule).
    private static func listsInMenu(_ summary: EngineExtensionSummary, manager: EngineExtensionManager,
                                    profileId: String, tab: ExtensionHostTab?) -> Bool {
        ExtensionToolbarRule.listsInMenu(
            isLoaded: summary.isLoaded, isEnabled: summary.isEnabled,
            hasActionInTab: manager.action(extensionId: summary.id, profileId: profileId, tab: tab) != nil)
    }

    /// A pinned button over `tab`: hidden while the extension is not set up
    /// in the profile (ExtensionToolbarRule).
    private static func showsPinnedButton(_ summary: EngineExtensionSummary, manager: EngineExtensionManager,
                                          profileId: String, tab: ExtensionHostTab?) -> Bool {
        ExtensionToolbarRule.showsPinnedButton(
            isLoaded: summary.isLoaded, isEnabled: summary.isEnabled,
            hasActionInTab: manager.action(extensionId: summary.id, profileId: profileId, tab: tab) != nil,
            isSetUp: summary.isSetUp)
    }

    /// Why a button does nothing in the selected tab, when it does nothing.
    private static func disabledReason(_ action: EngineExtensionAction?) -> String? {
        guard let action, !action.isEnabled else { return nil }
        return action.disabledReason
    }

    private static func toolTip(label: String, action: EngineExtensionAction?) -> String {
        disabledReason(action).map { "\(label)\n\($0)" } ?? label
    }

    /// The reason, said where the user clicked. The click came from this
    /// window, so ending a text field's editing first is expected; a
    /// popover ordered in during editing takes the app down (see CLAUDE.md).
    private func showReason(_ reason: String, from button: NSButton) {
        guard let window = button.window, let controller else { return }
        guard ExtensionsCoordinator.resignFieldEditor(in: window) else {
            NSLog("Browser: not showing why an extension's button does nothing: a text field would not end editing")
            return
        }
        let label = NSTextField(wrappingLabelWithString: reason)
        label.preferredMaxLayoutWidth = 260
        let size = label.fittingSize
        label.frame = NSRect(x: 12, y: 10, width: size.width, height: size.height)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 20))
        content.view.addSubview(label)
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        let anchor = controller.popoverAnchor(for: button)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func press(_ id: String) {
        guard let controller, controller.runsExtensions, let manager = ExtensionsCoordinator.shared.manager else { return }
        manager.performAction(extensionId: id, window: ExtensionsCoordinator.shared.windowHandle(for: controller))
    }

    @objc private func puzzleTapped(_ sender: NSButton) {
        guard let controller, controller.runsExtensions, let manager = ExtensionsCoordinator.shared.manager else { return }
        let profileId = controller.profile.id
        let menu = NSMenu()
        let activeTab = controller.activeTab.map { ExtensionsCoordinator.shared.tabHandle(for: $0, in: controller) }
        let all = manager.extensions(profileId: profileId)
        let running = all.filter { Self.listsInMenu($0, manager: manager, profileId: profileId, tab: activeTab) }
        if running.isEmpty {
            let empty = NSMenuItem(title: all.isEmpty ? "No Extensions Installed" : "No Extensions Turned On", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for summary in running {
            let action = manager.action(extensionId: summary.id, profileId: profileId, tab: activeTab)
            let badge = action?.badgeText ?? ""
            let item = NSMenuItem(title: badge.isEmpty ? summary.name : "\(summary.name)  (\(badge))",
                                  action: #selector(menuPress(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            item.image = Self.iconImage(action?.icon ?? summary.icon, name: summary.name)
            item.toolTip = Self.toolTip(label: action?.label ?? summary.name, action: action)
            item.isEnabled = action?.isEnabled ?? true
            if let reason = Self.disabledReason(action) {
                if #available(macOS 14.4, *) { item.subtitle = reason }
            }
            menu.addItem(item)
        }
        if !running.isEmpty {
            let pinMenu = NSMenu()
            for summary in running {
                let item = NSMenuItem(title: summary.name, action: #selector(menuTogglePin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = summary.id
                item.state = summary.isPinned ? .on : .off
                pinMenu.addItem(item)
            }
            let pinItem = NSMenuItem(title: "Pin to Toolbar", action: nil, keyEquivalent: "")
            pinItem.submenu = pinMenu
            menu.addItem(.separator())
            menu.addItem(pinItem)
        }
        menu.addItem(.separator())
        if let storeURL = controller.activeTab?.urlString, Self.isWebStoreDetailPage(storeURL),
           let id = ChromeExtensionID.find(in: storeURL), !all.contains(where: { $0.id == id }) {
            let add = NSMenuItem(title: "Add This Extension…", action: #selector(menuAddFromStore(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = storeURL
            menu.addItem(add)
        }
        let store = NSMenuItem(title: "Chrome Web Store", action: #selector(menuOpenStore(_:)), keyEquivalent: "")
        store.target = self
        menu.addItem(store)
        let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(menuManage(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    static func isWebStoreDetailPage(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "chromewebstore.google.com" || (host == "chrome.google.com" && url.contains("/webstore/"))
    }

    @objc private func menuPress(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // After the menu has gone, so the popup hangs from a settled button.
        DispatchQueue.main.async { [weak self] in self?.press(id) }
    }

    @objc private func menuTogglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let controller else { return }
        ExtensionsCoordinator.shared.manager?.setPinned(sender.state != .on, extensionId: id, profileId: controller.profile.id)
    }

    @objc private func menuAddFromStore(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String, let controller else { return }
        let profileId = controller.profile.id
        Task { @MainActor in
            do {
                try await ExtensionsCoordinator.shared.manager?.installFromWebStore(link, profileId: profileId)
            } catch {
                Self.report(error, in: controller.window)
            }
        }
    }

    @objc private func menuOpenStore(_ sender: NSMenuItem) {
        controller?.addTab(url: "https://chromewebstore.google.com/", makeActive: true)
    }

    @objc private func menuManage(_ sender: NSMenuItem) {
        guard let profile = controller?.profile else { return }
        ExtensionsWindowManager.shared.show(for: profile)
    }

    // MARK: - A pinned button's own menu

    private func contextMenu(for summary: EngineExtensionSummary) -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: summary.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = summary.id
            menu.addItem(item)
        }
        add("Unpin", #selector(contextUnpin(_:)))
        if summary.hasOptionsPage { add("Options", #selector(contextOptions(_:))) }
        if case .unpacked = summary.source { add("Reload", #selector(contextReload(_:))) }
        menu.addItem(.separator())
        add("Manage Extensions…", #selector(menuManage(_:)))
        return menu
    }

    @objc private func contextUnpin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let controller else { return }
        ExtensionsCoordinator.shared.manager?.setPinned(false, extensionId: id, profileId: controller.profile.id)
    }

    @objc private func contextOptions(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let controller else { return }
        ExtensionsCoordinator.shared.manager?.openOptionsPage(extensionId: id, profileId: controller.profile.id)
    }

    @objc private func contextReload(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let controller else { return }
        let profileId = controller.profile.id
        Task { @MainActor in
            do {
                try await ExtensionsCoordinator.shared.manager?.reload(extensionId: id, profileId: profileId)
            } catch {
                Self.report(error, in: controller.window)
            }
        }
    }

    /// An install or reload that failed, told as a sheet; a declined one
    /// (no description) says nothing.
    static func report(_ error: Error, in window: NSWindow?) {
        let text = (error as? LocalizedError).map { $0.errorDescription } ?? error.localizedDescription
        guard let text, !text.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "The extension couldn't be added"
        alert.informativeText = text
        if let window {
            guard ExtensionsCoordinator.resignFieldEditor(in: window) else {
                NSLog("Browser: extension error not shown, a text field would not end editing: %@", text)
                return
            }
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension ExtensionsToolbarController: TabLifecycleObserver {
    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard controller === self.controller else { return }
        switch event {
        case .becameActive, .navigated: refresh()
        default: break
        }
    }
}

/// A pinned extension's button: its icon, with the badge the extension sets
/// drawn in the corner.
final class ExtensionToolbarButton: NSButton {
    var extensionId: String?
    var badgeText = "" {
        didSet { if badgeText != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !badgeText.isEmpty else { return }
        let text = String(badgeText.prefix(4)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let badge = NSRect(x: bounds.maxX - size.width - 6, y: isFlipped ? bounds.maxY - 12 : 1,
                           width: size.width + 5, height: 11)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5.5, yRadius: 5.5).fill()
        text.draw(at: NSPoint(x: badge.minX + 2.5, y: badge.minY + (badge.height - size.height) / 2), withAttributes: attributes)
    }
}
