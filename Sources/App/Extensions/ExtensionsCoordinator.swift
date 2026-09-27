import AppKit

extension Notification.Name {
    /// A profile's extension list, or one of its toolbar buttons, changed.
    /// `object` is the profile id.
    static let browserExtensionsDidChange = Notification.Name("BrowserExtensionsDidChange")
    /// Something happened the user should hear about (installed, updated,
    /// failed). `object` is the profile id; `userInfo["message"]` the text.
    static let browserExtensionsNotice = Notification.Name("BrowserExtensionsNotice")
}

/// The app's side of the extension system: tells the engine's
/// EngineExtensionManager which windows and tabs exist as they come and go,
/// and answers what it asks back -- see ExtensionHost. Private windows are
/// never reported, so extensions never see or touch them.
///
/// Engine-agnostic: it only ever talks to `ActiveEngine.extensions`, and does
/// nothing at all where the engine has none.
final class ExtensionsCoordinator: NSObject, ExtensionHost, TabLifecycleObserver {
    static let shared = ExtensionsCoordinator()

    private var isActivated = false
    private var tabHandles: [UUID: ExtensionTabHandle] = [:]
    private var windowHandles: [ObjectIdentifier: ExtensionWindowHandle] = [:]
    private var lastActiveTab: [ObjectIdentifier: ExtensionTabHandle] = [:]
    private var pendingQuestion: Task<Bool, Never>?
    private var observers: [NSObjectProtocol] = []

    var manager: EngineExtensionManager? {
        ActiveEngine.capabilities.webExtensions ? ActiveEngine.extensions : nil
    }

    /// Idempotent; called as each browser window is built.
    func activate() {
        guard !isActivated, let manager else { return }
        isActivated = true
        manager.activate(host: self, storageDirectory: { profileId in
            guard !profileId.hasPrefix(Profile.privateIdPrefix) else { return nil }
            return URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId), isDirectory: true)
                .appendingPathComponent("Extensions", isDirectory: true)
        })
        TabLifecycleCenter.shared.addObserver(self)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let controller = (notification.object as? NSWindow)?.windowController as? BrowserWindowController,
                  !controller.isPrivate, let window = self.windowHandles[ObjectIdentifier(controller)] else { return }
            self.manager?.windowDidBecomeFocused(window)
        })
    }

    // MARK: - Handles

    func windowHandle(for controller: BrowserWindowController) -> ExtensionWindowHandle {
        let key = ObjectIdentifier(controller)
        if let existing = windowHandles[key], existing.controller === controller { return existing }
        let made = ExtensionWindowHandle(controller: controller, coordinator: self)
        windowHandles[key] = made
        return made
    }

    func tabHandle(for tab: Tab, in controller: BrowserWindowController) -> ExtensionTabHandle {
        if let existing = tabHandles[tab.id] {
            existing.controller = controller
            return existing
        }
        let made = ExtensionTabHandle(tab: tab, controller: controller, coordinator: self)
        tabHandles[tab.id] = made
        return made
    }

    // MARK: - TabLifecycleObserver

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard let manager, !controller.isPrivate, !tab.isPrivate else { return }
        let key = ObjectIdentifier(controller)
        switch event {
        case .opened:
            if windowHandles[key] == nil {
                manager.loadExtensions(profileId: controller.profile.id)
                manager.windowDidOpen(windowHandle(for: controller))
            }
            manager.tabDidOpen(tabHandle(for: tab, in: controller))
        case .becameActive:
            let handle = tabHandle(for: tab, in: controller)
            let previous = lastActiveTab[key]
            lastActiveTab[key] = handle
            manager.tabDidActivate(handle, previous: previous === handle ? nil : previous)
        case .navigated:
            manager.tabDidChange(tabHandle(for: tab, in: controller), [.url, .title, .loading])
        case .finishedLoading:
            manager.tabDidChange(tabHandle(for: tab, in: controller), [.title, .loading])
        case .closed:
            let windowIsClosing = controller.tabs.isEmpty
            if let handle = tabHandles.removeValue(forKey: tab.id) {
                manager.tabDidClose(handle, windowIsClosing: windowIsClosing)
                if lastActiveTab[key] === handle { lastActiveTab[key] = nil }
            }
            if windowIsClosing, let window = windowHandles[key] {
                // After the window's last tab has been reported.
                DispatchQueue.main.async { [weak self] in
                    guard let self, controller.tabs.isEmpty, self.windowHandles[key] === window else { return }
                    self.manager?.windowDidClose(window)
                    self.windowHandles[key] = nil
                    self.lastActiveTab[key] = nil
                }
            }
        }
    }

    // MARK: - ExtensionHost

    func extensionWindows(profileId: String) -> [ExtensionHostWindow] {
        var ordered: [ExtensionHostWindow] = []
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.orderedWindows {
            guard let controller = window.windowController as? BrowserWindowController,
                  controller.profile.id == profileId, !controller.isPrivate,
                  WindowManager.shared.windowControllers.contains(where: { $0 === controller }),
                  seen.insert(ObjectIdentifier(controller)).inserted
            else { continue }
            ordered.append(windowHandle(for: controller))
        }
        return ordered
    }

    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool) -> ExtensionHostWindow? {
        guard let profile = ProfileManager.shared.profile(id: profileId) else { return nil }
        let first = urls.first?.absoluteString ?? HomepagePreference.newWindowURL
        let controller = WindowManager.shared.openNewWindow(profile: profile, initialURL: first)
        for url in urls.dropFirst() {
            controller.addTab(url: url.absoluteString, makeActive: false)
        }
        if focused { controller.window?.makeKeyAndOrderFront(nil) }
        return windowHandle(for: controller)
    }

    /// One question at a time, as a sheet on the frontmost window: an alert
    /// run modally would stop every page and every other extension for as
    /// long as it waits, and an extension can ask when nobody is looking.
    @MainActor
    func extensionConfirm(_ request: ExtensionConsentRequest) async -> Bool {
        let previous = pendingQuestion
        let task = Task { @MainActor () -> Bool in
            _ = await previous?.value
            let alert = NSAlert()
            alert.messageText = request.title
            alert.informativeText = request.message
            if let icon = request.icon { alert.icon = icon }
            alert.addButton(withTitle: request.allowTitle)
            alert.addButton(withTitle: "Cancel")
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is BrowserWindowController })
            else {
                return alert.runModal() == .alertFirstButtonReturn
            }
            // A sheet ordered in while the omnibox holds focus trips AppKit's
            // completion-list assertion (see CLAUDE.md).
            Self.resignFieldEditor(in: window)
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        pendingQuestion = task
        return await task.value
    }

    static func resignFieldEditor(in window: NSWindow) {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            window.makeFirstResponder(nil)
        }
    }

    func extensionNotify(_ message: String, profileId: String) {
        NSLog("Browser: extensions: %@", message)
        NotificationCenter.default.post(name: .browserExtensionsNotice, object: profileId, userInfo: ["message": message])
    }

    func extensionsDidChange(profileId: String) {
        NotificationCenter.default.post(name: .browserExtensionsDidChange, object: profileId)
    }

    // MARK: - Menu

    /// Window > Extensions…
    @objc func showExtensions(_ sender: Any?) {
        let key = NSApp.keyWindow?.windowController as? BrowserWindowController
        let controller = (key?.isPrivate == false ? key : nil)
            ?? WindowManager.shared.windowControllers.first { !$0.isPrivate }
        guard let profile = controller?.profile ?? ProfileManager.shared.profiles.first else { return }
        ExtensionsWindowManager.shared.show(for: profile)
    }
}

/// A Tab, as the extension system is told about it.
final class ExtensionTabHandle: ExtensionHostTab {
    weak var tab: Tab?
    weak var controller: BrowserWindowController?
    private weak var coordinator: ExtensionsCoordinator?

    init(tab: Tab, controller: BrowserWindowController, coordinator: ExtensionsCoordinator) {
        self.tab = tab
        self.controller = controller
        self.coordinator = coordinator
    }

    private var index: Int? {
        guard let tab, let controller else { return nil }
        return controller.tabs.firstIndex { $0 === tab }
    }

    var extensionEngineTab: EngineTab? { tab?.browser }
    var extensionTitle: String { tab?.title ?? "" }
    var extensionURL: URL? {
        guard let string = tab?.urlString, !string.isEmpty else { return nil }
        return URL(string: string)
    }
    var extensionIsLoading: Bool { tab?.isLoading ?? false }
    var extensionIsPinned: Bool { tab?.isPinned ?? false }
    var extensionWindow: ExtensionHostWindow? {
        guard let controller, let coordinator else { return nil }
        return coordinator.windowHandle(for: controller)
    }

    func extensionLoad(_ url: URL) { tab?.load(url: url.absoluteString) }

    func extensionActivate() {
        guard let index, let controller else { return }
        controller.selectTab(at: index)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func extensionClose() {
        guard let index else { return }
        controller?.closeTab(at: index)
    }

    func extensionSetPinned(_ pinned: Bool) {
        guard let index, let tab, tab.isPinned != pinned else { return }
        if pinned { controller?.pinTab(at: index) } else { controller?.unpinTab(at: index) }
    }
}

/// A BrowserWindowController, as the extension system is told about it.
final class ExtensionWindowHandle: ExtensionHostWindow {
    weak var controller: BrowserWindowController?
    private weak var coordinator: ExtensionsCoordinator?
    let extensionProfileId: String

    init(controller: BrowserWindowController, coordinator: ExtensionsCoordinator) {
        self.controller = controller
        self.coordinator = coordinator
        extensionProfileId = controller.profile.id
    }

    var extensionTabs: [ExtensionHostTab] {
        guard let controller, let coordinator else { return [] }
        return controller.tabs.map { coordinator.tabHandle(for: $0, in: controller) }
    }

    var extensionActiveTab: ExtensionHostTab? {
        guard let controller, let coordinator, let tab = controller.activeTab else { return nil }
        return coordinator.tabHandle(for: tab, in: controller)
    }

    var extensionNSWindow: NSWindow? { controller?.window }

    func extensionOpenTab(url: URL?, active: Bool) -> ExtensionHostTab? {
        guard let controller, let coordinator else { return nil }
        let tab = controller.addTab(url: url?.absoluteString ?? "about:blank", makeActive: active)
        return coordinator.tabHandle(for: tab, in: controller)
    }

    func extensionClose() { controller?.window?.performClose(nil) }

    func extensionPopupAnchor(forExtension id: String) -> NSView? {
        (controller?.window as? BrowserWindow)?.extensionsToolbar.anchor(forExtension: id)
    }
}

enum ExtensionsWindowManager {
    static let shared = ProfileWindowRegistry<ExtensionsWindowController>()
}
