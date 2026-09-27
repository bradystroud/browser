import AppKit

/// One HiddenElementStore per profile. A private window's profile gets an
/// in-memory store, so nothing it hides is ever written under
/// `<profiles-root>/private-<UUID>/`.
enum HiddenElementStores {
    private static var cache: [String: HiddenElementStore] = [:]

    static func store(forProfileId profileId: String) -> HiddenElementStore {
        if let existing = cache[profileId] { return existing }
        let store: HiddenElementStore
        if profileId.hasPrefix(Profile.privateIdPrefix) {
            store = HiddenElementStore(fileURL: nil)
        } else {
            let directory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            store = HiddenElementStore(fileURL: directory.appendingPathComponent("hidden-elements.json"))
        }
        cache[profileId] = store
        return store
    }

    /// A private window's store dies with the window: the next private
    /// window has a new id, so nothing would ever read this one again.
    static func discard(profileId: String) {
        guard profileId.hasPrefix(Profile.privateIdPrefix) else { return }
        cache.removeValue(forKey: profileId)
    }
}

/// The element hider: pick an element on a page to hide it on that whole
/// site from then on, and see or restore what has been hidden.
///
/// Hiding is a stylesheet, not a DOM edit. Every tab carries its profile's
/// site -> stylesheet map (Tab.siteStyleSheets), and the engine applies the
/// right sheet at document start, so a hidden element is never painted and
/// never seen flashing in before it goes.
final class ElementHiderCoordinator: NSObject, NSMenuItemValidation, TabLifecycleObserver {
    static let shared = ElementHiderCoordinator()

    private var isActivated = false
    /// Tabs currently in pick mode. Identity only -- nothing here keeps a
    /// Tab alive.
    private let pickingTabs = NSHashTable<Tab>.weakObjects()
    private var escapeMonitor: Any?
    private var hasAutoPresented = false

    private override init() {
        super.init()
    }

    /// Idempotent; called from BrowserWindow's init alongside the other
    /// page-message features, so it runs before the first tab exists.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        TabLifecycleCenter.shared.addObserver(self)
        PageMessageDispatcher.shared.register(types: [ElementHiderScript.pickedMessageType, ElementHiderScript.endedMessageType]) { [weak self] message in
            self?.handle(message)
        }
    }

    // MARK: - Menu

    @objc func toggleHidingMode(_ sender: Any?) {
        guard let tab = WindowManager.shared.keyBrowserWindowController?.activeTab else { return }
        if isPicking(tab) {
            stopPicking(tab)
        } else if Self.site(of: tab) != nil {
            startPicking(tab)
        }
    }

    @objc func showHiddenElements(_ sender: Any?) {
        guard let controller = WindowManager.shared.keyBrowserWindowController,
              let tab = controller.activeTab
        else { return }
        stopPicking(tab)
        HiddenElementsSheetController.shared.present(in: controller)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tab = WindowManager.shared.keyBrowserWindowController?.activeTab,
              Self.site(of: tab) != nil
        else {
            menuItem.state = .off
            return false
        }
        if menuItem.action == #selector(toggleHidingMode(_:)) {
            menuItem.state = isPicking(tab) ? .on : .off
        }
        return true
    }

    // MARK: - Pick mode

    func isPicking(_ tab: Tab) -> Bool {
        pickingTabs.contains(tab)
    }

    func startPicking(_ tab: Tab) {
        guard !isPicking(tab) else { return }
        pickingTabs.add(tab)
        tab.executeJavaScript(ElementHiderScript.start)
        installEscapeMonitor()
    }

    func stopPicking(_ tab: Tab) {
        guard isPicking(tab) else { return }
        pickingTabs.remove(tab)
        tab.executeJavaScript(ElementHiderScript.stop)
        removeEscapeMonitorIfIdle()
    }

    /// Escape has to end pick mode wherever keyboard focus is -- the
    /// omnibox, the tab strip, or a page that never took focus -- and a
    /// page's own key handler only hears it in the last case.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
                  let controller = event.window?.windowController as? BrowserWindowController,
                  let tab = controller.activeTab,
                  self.isPicking(tab)
            else { return event }
            self.stopPicking(tab)
            return nil
        }
    }

    private func removeEscapeMonitorIfIdle() {
        guard pickingTabs.allObjects.isEmpty, let monitor = escapeMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeMonitor = nil
    }

    // MARK: - Page messages

    private struct PickedPayload: Decodable {
        let selector: String
        let label: String?
        let note: String?
    }

    private func handle(_ message: PageMessage) {
        let tab = message.tab
        defer { tab.respondToPageMessage(requestId: message.requestId, success: true, response: "") }
        switch message.type {
        case ElementHiderScript.endedMessageType:
            pickingTabs.remove(tab)
            removeEscapeMonitorIfIdle()
        case ElementHiderScript.pickedMessageType:
            // Only a pick the user asked for counts: any page can send this
            // type at any moment, and it must not be able to hide parts of
            // itself behind the user's back.
            guard isPicking(tab),
                  let origin = message.origin,
                  let data = message.request.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(PickedPayload.self, from: data)
                  else { return }
            let site = HiddenElementStore.site(forHost: origin.host)
            let store = HiddenElementStores.store(forProfileId: tab.profileId)
            if store.hide(selector: payload.selector, label: payload.label ?? "", note: payload.note ?? "", onSite: site) {
                siteStyleSheetsChanged(profileId: tab.profileId)
            } else {
                NSLog("Browser: element hider ignored a selector it could not use on %@", site)
            }
        default:
            break
        }
    }

    // MARK: - Applying

    /// Pushes a profile's current sheets to every open tab in it, which
    /// also updates the documents they are showing right now.
    func siteStyleSheetsChanged(profileId: String) {
        let sheets = HiddenElementStores.store(forProfileId: profileId).styleSheetsBySite
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs where tab.profileId == profileId {
                tab.siteStyleSheets = sheets
            }
        }
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        switch event {
        case .opened:
            tab.siteStyleSheets = HiddenElementStores.store(forProfileId: tab.profileId).styleSheetsBySite
        case .navigated:
            // A new document has no picker in it, and a same-document change
            // usually means the page under the pointer is not the one the
            // user started pointing at.
            stopPicking(tab)
        case .becameActive:
            for other in controller.tabs where other !== tab {
                stopPicking(other)
            }
        case .closed:
            pickingTabs.remove(tab)
            removeEscapeMonitorIfIdle()
            if tab.isPrivate, !WindowManager.shared.windowControllers.contains(where: { $0.profile.id == tab.profileId }) {
                HiddenElementStores.discard(profileId: tab.profileId)
            }
        case .finishedLoading:
            if !hasAutoPresented, tab === controller.activeTab,
               CommandLine.arguments.contains(HiddenElementsSheetController.autoPresentFlag) {
                hasAutoPresented = HiddenElementsSheetController.shared.present(in: controller)
            }
        }
    }

    /// The site (registrable domain) a tab's page belongs to, or nil for a
    /// page with nothing to hide things on -- the start page, a data: URL.
    static func site(of tab: Tab) -> String? {
        SiteIdentity.host(forURLString: tab.urlString).map(HiddenElementStore.site(forHost:))
    }
}
