import AppKit
import WebKit

// Chrome extensions on the WebKit engine, through Apple's WKWebExtension --
// the same engine Safari's extensions run on, reading the same manifest.json
// a Chrome extension ships. What lives here is the browser's half of that
// contract: one WKWebExtensionController per profile, installing from a
// folder or the Chrome Web Store, the permissions the user agreed to, and
// answers to what the controller asks about tabs, windows and popups.
//
// Parts of the approach (stable chrome-extension:// origins, the shared user
// agent, staggered loading, reviving a worker that failed to start) follow
// Search (https://github.com/driceroland/Search, MIT) -- see
// ChromeExtensionPackage.swift for its notice.

/// One profile's extensions: its controller, what is installed, what is
/// running, and the adapters its tabs and windows are known by.
@available(macOS 15.4, *)
final class WebKitExtensionProfile {
    let profileId: String
    let directory: URL
    let controller: WKWebExtensionController
    var list: InstalledWebExtensionList
    var contexts: [String: WKWebExtensionContext] = [:]
    var errors: [String: [String]] = [:]
    var loadStarted = false
    var busy: Set<String> = []
    var revivedAt: [String: Date] = [:]
    /// Revivals since the user last loaded or reloaded the extension.
    var revivals: [String: Int] = [:]
    var errorObservers: [String: NSObjectProtocol] = [:]
    /// The window whose toolbar button was pressed last, for the popup to
    /// hang from.
    weak var actionWindow: ExtensionHostWindow?
    weak var shownPopover: NSPopover?
    var shownPopoverExtensionId: String?
    private var tabAdapters: [ObjectIdentifier: WebKitExtensionTabAdapter] = [:]
    private var windowAdapters: [ObjectIdentifier: WebKitExtensionWindowAdapter] = [:]

    init(profileId: String, directory: URL, controller: WKWebExtensionController) {
        self.profileId = profileId
        self.directory = directory
        self.controller = controller
        list = InstalledWebExtensionList.load(from: directory.appendingPathComponent("installed.json"))
    }

    func record(_ id: String) -> InstalledWebExtension? { list.extensions.first { $0.id == id } }

    func update(_ id: String, _ change: (inout InstalledWebExtension) -> Void) {
        guard let index = list.extensions.firstIndex(where: { $0.id == id }) else { return }
        change(&list.extensions[index])
    }

    /// Only an install creates the folder. Anything else that saves -- an
    /// update check, a toggle -- must not bring back a folder that was
    /// deleted with its profile.
    func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save() {
        do {
            try list.save(to: directory.appendingPathComponent("installed.json"))
        } catch {
            NSLog("Browser: couldn't save the extension list for profile %@: %@", profileId, error.localizedDescription)
        }
    }

    /// Where a store extension is unpacked. An unpacked one is read from its
    /// own folder instead (`resourceFolder(for:)`).
    func storeFolder(for id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    func resourceFolder(for record: InstalledWebExtension) -> URL {
        switch record.source {
        case .webStore: return storeFolder(for: record.id)
        case .unpacked: return URL(fileURLWithPath: record.unpackedPath ?? "/nonexistent", isDirectory: true)
        }
    }

    /// A message already on the list is not added again: WebKit reports
    /// every error the context has each time the list changes.
    func noteError(_ text: String, for id: String) {
        guard errors[id]?.contains(text) != true else { return }
        errors[id, default: []].append(text)
        errors[id] = Array(errors[id]!.suffix(20))
    }

    func tabAdapter(for tab: ExtensionHostTab) -> WebKitExtensionTabAdapter {
        let key = ObjectIdentifier(tab)
        if let existing = tabAdapters[key], existing.hostTab === tab { return existing }
        let made = WebKitExtensionTabAdapter(hostTab: tab, profile: self)
        tabAdapters[key] = made
        return made
    }

    func existingTabAdapter(for tab: ExtensionHostTab) -> WebKitExtensionTabAdapter? {
        guard let adapter = tabAdapters[ObjectIdentifier(tab)], adapter.hostTab === tab else { return nil }
        return adapter
    }

    func forgetTab(_ tab: ExtensionHostTab) { tabAdapters[ObjectIdentifier(tab)] = nil }

    func windowAdapter(for window: ExtensionHostWindow) -> WebKitExtensionWindowAdapter {
        let key = ObjectIdentifier(window)
        if let existing = windowAdapters[key], existing.hostWindow === window { return existing }
        let made = WebKitExtensionWindowAdapter(hostWindow: window, profile: self)
        windowAdapters[key] = made
        return made
    }

    func forgetWindow(_ window: ExtensionHostWindow) { windowAdapters[ObjectIdentifier(window)] = nil }
}

@available(macOS 15.4, *)
final class WebKitExtensionManager: NSObject, EngineExtensionManager {
    static let shared = WebKitExtensionManager()

    /// An extension's pages are served from chrome-extension://<id>/, the
    /// address they have in Chrome. Sites and servers look for an extension
    /// at that origin (some only let their own extension in by it), and the
    /// origin never changes between launches, which is what keeps the
    /// localStorage and IndexedDB an extension's pages file under it.
    static let pageScheme = "chrome-extension"

    private weak var host: ExtensionHost?
    private var storageDirectory: ((String) -> URL?)?
    private var profiles: [String: WebKitExtensionProfile] = [:]
    private var updateTimer: Timer?

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.pageScheme)
        super.init()
    }

    var isActive: Bool { host != nil }

    func activate(host: ExtensionHost, storageDirectory: @escaping (String) -> URL?) {
        self.host = host
        self.storageDirectory = storageDirectory
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            for profile in self.profiles.values where profile.loadStarted {
                let id = profile.profileId
                Task { @MainActor in await self.checkForUpdates(profileId: id, force: false) }
            }
        }
    }

    // MARK: - Profiles

    /// Nil for a profile with nowhere to keep extensions -- a private one.
    func profile(for profileId: String) -> WebKitExtensionProfile? {
        if let existing = profiles[profileId] { return existing }
        guard isActive, let directory = storageDirectory?(profileId) else { return nil }
        let identifier = ProfileDataStoreKey.identifier(forProfileId: profileId)
        let configuration = WKWebExtensionController.Configuration(identifier: identifier)
        let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        configuration.defaultWebsiteDataStore = dataStore
        let views: WKWebViewConfiguration = configuration.webViewConfiguration
        views.websiteDataStore = dataStore
        // The same user agent as the tabs, to the letter. WebKit gives
        // extension workers the user agent of the last page that loaded and,
        // when it differs, restarts the running workers to apply it -- and
        // an extension's worker it then never starts again.
        views.applicationNameForUserAgent = SafariUserAgent.applicationName
        configuration.webViewConfiguration = views
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        let profile = WebKitExtensionProfile(profileId: profileId, directory: directory, controller: controller)
        WebKitExtensionInstaller.removeLeftovers(in: directory)
        profiles[profileId] = profile
        return profile
    }

    private func profile(for controller: WKWebExtensionController) -> WebKitExtensionProfile? {
        profiles.values.first { $0.controller === controller }
    }

    /// The configuration a new tab's web view is built from. An extension's
    /// own page can only be served to a view built from that extension's
    /// configuration, so a tab opening one gets it; any other tab gets its
    /// profile's controller, which is what injects content scripts. A tab
    /// built before the profile had a controller is never reached by
    /// extensions, so this is called for every tab.
    func configuration(for base: WKWebViewConfiguration, profileId: String, initialURL: String) -> WKWebViewConfiguration {
        guard let profile = profile(for: profileId) else { return base }
        if let url = URL(string: initialURL), url.scheme == Self.pageScheme, let id = url.host,
           let context = profile.contexts[id], let page = context.webViewConfiguration {
            // The page bridge and friends each register a named handler on
            // the tab's controller; a fresh one keeps them off the one the
            // extension's configuration copies share.
            page.userContentController = WKUserContentController()
            page.applicationNameForUserAgent = base.applicationNameForUserAgent
            return page
        }
        base.webExtensionController = profile.controller
        return base
    }

    func unloadProfile(profileId: String) {
        guard let profile = profiles.removeValue(forKey: profileId) else { return }
        profile.shownPopover?.performClose(nil)
        for id in Array(profile.contexts.keys) { unload(id, in: profile) }
        for observer in profile.errorObservers.values { NotificationCenter.default.removeObserver(observer) }
        profile.errorObservers = [:]
        profile.controller.delegate = nil
    }

    // MARK: - Loading

    func loadExtensions(profileId: String) {
        guard let profile = profile(for: profileId), !profile.loadStarted else { return }
        profile.loadStarted = true
        Task { @MainActor in
            // One after another, a moment apart: started all at once, WebKit
            // fails some of their workers and never tries them again.
            for record in profile.list.extensions where record.enabled {
                await self.load(record.id, in: profile)
                if profile.contexts[record.id]?.webExtension.hasBackgroundContent == true {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            await self.checkForUpdates(profileId: profileId, force: false)
        }
    }

    @MainActor @discardableResult
    private func load(_ id: String, in profile: WebKitExtensionProfile) async -> Bool {
        guard let record = profile.record(id), profile.contexts[id] == nil else { return false }
        do {
            let found = try await WKWebExtension(resourceBaseURL: profile.resourceFolder(for: record))
            try start(found, record: record, in: profile)
            return true
        } catch {
            profile.noteError(error.localizedDescription, for: id)
            NSLog("Browser: couldn't load extension %@: %@", id, error.localizedDescription)
            host?.extensionsDidChange(profileId: profile.profileId)
            return false
        }
    }

    private func start(_ found: WKWebExtension, record: InstalledWebExtension, in profile: WebKitExtensionProfile) throws {
        let context = WKWebExtensionContext(for: found)
        context.uniqueIdentifier = record.id
        if let base = URL(string: "\(Self.pageScheme)://\(record.id)/") { context.baseURL = base }
        context.isInspectable = true
        Self.apply(record.grants, to: context)
        try profile.controller.load(context)
        profile.contexts[record.id] = context
        watchErrors(of: context, in: profile)
        host?.extensionsDidChange(profileId: profile.profileId)
    }

    /// Only what the user agreed to is granted -- not simply everything the
    /// manifest on disk asks for today, which for an unpacked extension
    /// can change between one launch and the next.
    private static func apply(_ grants: [String], to context: WKWebExtensionContext) {
        let agreed = Set(grants)
        let found = context.webExtension
        for permission in found.requestedPermissions.union(found.optionalPermissions)
        where agreed.contains("perm:" + permission.rawValue) {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        // A stored pattern may be narrower than the one the manifest
        // declares (permissions.request for one site under an optional
        // "https://*/*"); it is granted as stored, if a declared one covers it.
        let declared = found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns)
        for string in WebExtensionGrants.matchPatterns(in: grants) {
            guard let pattern = try? WKWebExtension.MatchPattern(string: string),
                  declared.contains(where: { $0.matches(pattern) }) else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func unload(_ id: String, in profile: WebKitExtensionProfile) {
        if profile.shownPopoverExtensionId == id { profile.shownPopover?.performClose(nil) }
        if let observer = profile.errorObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let context = profile.contexts.removeValue(forKey: id) else { return }
        do {
            try profile.controller.unload(context)
        } catch {
            NSLog("Browser: couldn't unload extension %@: %@", id, error.localizedDescription)
        }
        host?.extensionsDidChange(profileId: profile.profileId)
    }

    /// WebKit records a worker that failed to start as an error on its
    /// context and then doesn't try again, which would leave the extension
    /// dead until someone noticed. It is unloaded and loaded again, as a
    /// relaunch would -- at most once a minute and `maximumRevivals` times,
    /// so one that can never start doesn't go round in circles. A Reload
    /// from the user starts the count again.
    private static let maximumRevivals = 3

    private func watchErrors(of context: WKWebExtensionContext, in profile: WebKitExtensionProfile) {
        let id = context.uniqueIdentifier
        if let old = profile.errorObservers[id] { NotificationCenter.default.removeObserver(old) }
        profile.errorObservers[id] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main
        ) { [weak self, weak profile, weak context] _ in
            guard let self, let profile, let context, profile.contexts[id] === context else { return }
            for error in context.errors {
                profile.noteError(error.localizedDescription, for: id)
            }
            self.host?.extensionsDidChange(profileId: profile.profileId)
            let workerFailed = context.errors.contains {
                let error = $0 as NSError
                return error.domain == WKWebExtensionContext.errorDomain
                    && error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
            }
            guard workerFailed, (profile.revivals[id] ?? 0) < Self.maximumRevivals,
                  Date().timeIntervalSince(profile.revivedAt[id] ?? .distantPast) > 60 else { return }
            profile.revivedAt[id] = Date()
            profile.revivals[id, default: 0] += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak profile] in
                guard let self, let profile, profile.contexts[id] === context else { return }
                self.unload(id, in: profile)
                Task { @MainActor in await self.load(id, in: profile) }
            }
        }
    }

    // MARK: - Summaries

    func extensions(profileId: String) -> [EngineExtensionSummary] {
        guard let profile = profile(for: profileId) else { return [] }
        return profile.list.extensions.map { record in
            let context = profile.contexts[record.id]
            let found = context?.webExtension
            let source: EngineExtensionSource = record.source == .unpacked
                ? .unpacked(path: record.unpackedPath ?? "")
                : .webStore
            return EngineExtensionSummary(
                id: record.id,
                name: found?.displayName ?? record.name,
                version: found?.displayVersion ?? found?.version ?? record.version,
                description: found?.displayDescription ?? "",
                icon: found?.icon(for: CGSize(width: 32, height: 32)),
                source: source,
                isEnabled: record.enabled,
                isPinned: record.pinned,
                isLoaded: context?.isLoaded ?? false,
                hasOptionsPage: context?.optionsPageURL != nil,
                errors: profile.errors[record.id] ?? [])
        }
    }

    func action(extensionId: String, profileId: String, tab: ExtensionHostTab?) -> EngineExtensionAction? {
        guard let profile = profiles[profileId], let context = profile.contexts[extensionId] else { return nil }
        let adapter = tab.map { profile.tabAdapter(for: $0) }
        guard let action = context.action(for: adapter) else { return nil }
        let name = context.webExtension.displayName ?? profile.record(extensionId)?.name ?? extensionId
        return EngineExtensionAction(
            label: action.label.isEmpty ? name : action.label,
            icon: action.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)),
            badgeText: action.badgeText,
            isEnabled: action.isEnabled)
    }

    // MARK: - Installing

    @MainActor
    func installFromWebStore(_ linkOrID: String, profileId: String) async throws {
        guard let profile = profile(for: profileId) else { throw WebKitExtensionError.unavailable }
        guard let id = ChromeExtensionID.find(in: linkOrID) else { throw WebKitExtensionError.notAWebStoreLink }
        if let existing = profile.record(id) { throw WebKitExtensionError.alreadyInstalled(existing.name) }
        guard profile.busy.insert(id).inserted else { throw WebKitExtensionError.busy }
        defer { profile.busy.remove(id) }
        try profile.createDirectory()

        let staged = try await WebKitExtensionInstaller.downloadAndStage(id: id, in: profile.directory)
        defer { try? FileManager.default.removeItem(at: staged) }
        let found = try await WKWebExtension(resourceBaseURL: staged)
        let name = found.displayName ?? id
        let grants = Self.grants(for: found)
        guard await consent(title: "Add “\(name)”?", grants: grants, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Add Extension") else {
            throw WebKitExtensionError.cancelled
        }
        guard profile.record(id) == nil else { throw WebKitExtensionError.alreadyInstalled(name) }
        try WebKitExtensionInstaller.replace(profile.storeFolder(for: id), with: staged)
        let record = InstalledWebExtension(id: id, source: .webStore, name: name, version: found.version ?? "0", grants: grants)
        profile.list.extensions.append(record)
        profile.save()
        let installed = try await WKWebExtension(resourceBaseURL: profile.storeFolder(for: id))
        try start(installed, record: record, in: profile)
        host?.extensionNotify("\(name) was added.", profileId: profileId)
    }

    @MainActor
    func loadUnpacked(folder: URL, profileId: String) async throws {
        guard let profile = profile(for: profileId) else { throw WebKitExtensionError.unavailable }
        let folder = URL(fileURLWithPath: folder.resolvingSymlinksInPath().path, isDirectory: true)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw WebKitExtensionError.noManifest }
        let found = try await WKWebExtension(resourceBaseURL: folder)
        // As in Chrome: the id a manifest's "key" pins, else one made from
        // the folder's path, so reloading the same folder keeps its storage.
        let id = (found.manifest["key"] as? String).flatMap(ChromeExtensionID.from(manifestKey:))
            ?? ChromeExtensionID.fromUnpackedPath(folder.path)
        if let existing = profile.record(id) {
            guard existing.source == .unpacked, existing.unpackedPath == folder.path else {
                throw WebKitExtensionError.alreadyInstalled(existing.name)
            }
            try await reload(extensionId: id, profileId: profileId)
            return
        }
        let name = found.displayName ?? folder.lastPathComponent
        let grants = Self.grants(for: found)
        guard await consent(title: "Load “\(name)”?", grants: grants, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Load Extension") else {
            throw WebKitExtensionError.cancelled
        }
        let record = InstalledWebExtension(id: id, source: .unpacked, name: name, version: found.version ?? "0",
                                           unpackedPath: folder.path, grants: grants)
        try profile.createDirectory()
        profile.list.extensions.append(record)
        profile.save()
        try start(found, record: record, in: profile)
        host?.extensionNotify("\(name) was loaded.", profileId: profileId)
    }

    @MainActor
    func reload(extensionId id: String, profileId: String) async throws {
        guard let profile = profile(for: profileId) else { throw WebKitExtensionError.unavailable }
        guard let record = profile.record(id) else { throw WebKitExtensionError.notInstalled }
        guard profile.busy.insert(id).inserted else { throw WebKitExtensionError.busy }
        defer { profile.busy.remove(id) }
        let folder = profile.resourceFolder(for: record)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            throw WebKitExtensionError.noManifest
        }
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let name = found.displayName ?? record.name
        let requested = Self.grants(for: found)
        let added = WebExtensionGrants.added(requested, beyond: record.grants)
        if !added.isEmpty {
            guard await consent(title: "“\(name)” wants more access", grants: added, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Allow") else {
                throw WebKitExtensionError.cancelled
            }
        }
        unload(id, in: profile)
        profile.errors[id] = nil
        profile.revivals[id] = nil
        profile.update(id) {
            $0.name = name
            $0.version = found.version ?? $0.version
            $0.grants = Array(Set($0.grants).union(requested)).sorted()
        }
        profile.save()
        if let updated = profile.record(id), updated.enabled {
            try start(found, record: updated, in: profile)
        }
    }

    func remove(extensionId id: String, profileId: String) {
        guard let profile = profiles[profileId], let record = profile.record(id) else { return }
        // An install, reload or update in flight would put its files back
        // after they were deleted.
        guard profile.busy.insert(id).inserted else {
            host?.extensionNotify("\(record.name) is being updated; try removing it again in a moment.", profileId: profileId)
            return
        }
        let finish = { [weak self, weak profile] in
            guard let self, let profile else { return }
            defer { profile.busy.remove(id) }
            self.unload(id, in: profile)
            profile.list.extensions.removeAll { $0.id == id }
            profile.errors[id] = nil
            profile.save()
            // A developer's own folder is theirs; only a copy this app
            // unpacked is deleted.
            if record.source == .webStore {
                try? FileManager.default.removeItem(at: profile.storeFolder(for: id))
            }
            self.host?.extensionsDidChange(profileId: profileId)
        }
        // Its storage goes with it; that needs it loaded to be found.
        guard let context = profile.contexts[id] else { return finish() }
        let types = WKWebExtensionController.allExtensionDataTypes
        profile.controller.fetchDataRecord(ofTypes: types, for: context) { [weak profile] dataRecord in
            guard let profile, let dataRecord else { return finish() }
            profile.controller.removeData(ofTypes: types, from: [dataRecord]) { finish() }
        }
    }

    func setEnabled(_ enabled: Bool, extensionId id: String, profileId: String) {
        guard let profile = profiles[profileId], profile.record(id) != nil else { return }
        profile.update(id) { $0.enabled = enabled }
        profile.save()
        if enabled {
            profile.revivals[id] = nil
            Task { @MainActor in await self.load(id, in: profile) }
        } else {
            unload(id, in: profile)
        }
        host?.extensionsDidChange(profileId: profileId)
    }

    func setPinned(_ pinned: Bool, extensionId id: String, profileId: String) {
        guard let profile = profiles[profileId], profile.record(id) != nil else { return }
        profile.update(id) { $0.pinned = pinned }
        profile.save()
        host?.extensionsDidChange(profileId: profileId)
    }

    func openOptionsPage(extensionId id: String, profileId: String) {
        guard let url = profiles[profileId]?.contexts[id]?.optionsPageURL else { return }
        openInNewTab(url, profileId: profileId)
    }

    @discardableResult
    private func openInNewTab(_ url: URL, profileId: String) -> ExtensionHostTab? {
        if let window = host?.extensionWindows(profileId: profileId).first {
            return window.extensionOpenTab(url: url, active: true)
        }
        return host?.extensionOpenWindow(profileId: profileId, urls: [url], focused: true)?.extensionActiveTab
    }

    func performAction(extensionId id: String, window: ExtensionHostWindow) {
        guard let profile = profiles[window.extensionProfileId], let context = profile.contexts[id] else { return }
        // A second press on the button of an open popup closes it.
        if profile.shownPopoverExtensionId == id, let shown = profile.shownPopover, shown.isShown {
            shown.performClose(nil)
            return
        }
        profile.actionWindow = window
        let tab = window.extensionActiveTab.map { profile.tabAdapter(for: $0) }
        if let tab { context.userGesturePerformed(in: tab) }
        context.performAction(for: tab)
    }

    // MARK: - Updates

    @MainActor @discardableResult
    func checkForUpdates(profileId: String, force: Bool) async -> Int {
        guard let profile = profile(for: profileId) else { return 0 }
        guard force || profile.list.isUpdateCheckDue() else { return 0 }
        profile.list.lastUpdateCheck = Date()
        profile.save()
        var updated = 0
        for record in profile.list.extensions where record.source == .webStore {
            if await update(record.id, in: profile) { updated += 1 }
        }
        return updated
    }

    @MainActor
    private func update(_ id: String, in profile: WebKitExtensionProfile) async -> Bool {
        guard let record = profile.record(id), profile.busy.insert(id).inserted else { return false }
        defer { profile.busy.remove(id) }
        let checkURL = ChromeWebStore.updateCheckURL(for: id, installedVersion: record.version)
        guard let (data, response) = try? await URLSession.shared.data(from: checkURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let offered = ChromeExtensionUpdateCheck.parse(data).first(where: { $0.appID == id })?
                .availableUpdate(over: record.version)
        else { return false }

        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        do {
            staged = try await WebKitExtensionInstaller.downloadAndStage(id: id, in: profile.directory)
            guard let staged else { return false }
            let found = try await WKWebExtension(resourceBaseURL: staged)
            // The package itself has to be the newer version the check
            // promised, or nothing is swapped.
            if let current = ChromeExtensionVersion(record.version) {
                guard let packaged = found.version.flatMap(ChromeExtensionVersion.init), packaged > current else { return false }
            }
            let name = found.displayName ?? record.name
            let requested = Self.grants(for: found)
            let added = WebExtensionGrants.added(requested, beyond: record.grants)
            if !added.isEmpty {
                let title = "An update to “\(name)” wants more access"
                guard await consent(title: title, grants: added, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Update") else {
                    return false
                }
            }
            guard profile.record(id) != nil, profiles[profile.profileId] === profile else { return false }
            let wasLoaded = profile.contexts[id] != nil
            unload(id, in: profile)
            try WebKitExtensionInstaller.replace(profile.storeFolder(for: id), with: staged)
            profile.update(id) {
                $0.name = name
                $0.version = found.version ?? offered.description
                $0.grants = Array(Set($0.grants).union(requested)).sorted()
            }
            profile.save()
            if wasLoaded || profile.record(id)?.enabled == true {
                await load(id, in: profile)
            }
            host?.extensionNotify("\(name) was updated to \(found.version ?? offered.description).", profileId: profile.profileId)
            return true
        } catch {
            NSLog("Browser: update of extension %@ failed: %@", id, error.localizedDescription)
            profile.noteError("Update failed: \(error.localizedDescription)", for: id)
            if profile.contexts[id] == nil, profile.record(id)?.enabled == true { await load(id, in: profile) }
            return false
        }
    }

    // MARK: - Asking

    /// What an extension may do, as stored and compared: its API permissions
    /// and every site pattern it reaches, content-script matches included.
    static func grants(for found: WKWebExtension) -> [String] {
        WebExtensionGrants.make(
            permissions: found.requestedPermissions.map(\.rawValue),
            matchPatterns: found.allRequestedMatchPatterns.map(\.string))
    }

    /// `grants` in words, most sweeping first.
    static func describe(_ grants: [String]) -> [String] {
        var lines: [String] = []
        let patterns = WebExtensionGrants.matchPatterns(in: grants)
        if patterns.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.contains("://*/") }) {
            lines.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = Array(Set(patterns.compactMap { (try? WKWebExtension.MatchPattern(string: $0))?.host }.filter { !$0.isEmpty })).sorted()
            let shown = hosts.prefix(4).joined(separator: ", ")
            lines.append("Read and change what's on " + shown + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [String: String] = [
            "tabs": "See your open tabs and their addresses",
            "history": "Read and change your browsing history",
            "bookmarks": "Read and change your bookmarks",
            "cookies": "Read and change cookies",
            "webNavigation": "See where you go",
            "webRequest": "See the requests pages make",
            "declarativeNetRequest": "Block or change requests pages make",
            "declarativeNetRequestWithHostAccess": "Block or change requests pages make",
            "declarativeNetRequestFeedback": "See which requests it blocked",
            "clipboardRead": "Read what you copy",
            "clipboardWrite": "Write to the clipboard",
            "nativeMessaging": "Talk to apps on this Mac",
            "scripting": "Run scripts in pages",
            "downloads": "Manage your downloads",
            "notifications": "Show notifications",
            "contextMenus": "Add items to the page's menu",
            "menus": "Add items to the page's menu",
            "privacy": "Change your privacy settings",
            "proxy": "Change your proxy settings",
            "management": "See your other extensions",
        ]
        var seen = Set<String>()
        for permission in WebExtensionGrants.permissions(in: grants) {
            let line = words[permission] ?? "Use the “\(permission)” permission"
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines
    }

    @MainActor
    private func consent(title: String, grants: [String], icon: NSImage?, allow: String) async -> Bool {
        guard let host else { return false }
        let lines = Self.describe(grants)
        let message = lines.isEmpty
            ? "It doesn't ask for any special access."
            : "It will be able to:\n• " + lines.joined(separator: "\n• ")
        return await host.extensionConfirm(ExtensionConsentRequest(title: title, message: message, icon: icon, allowTitle: allow))
    }

    // MARK: - Tabs and windows, as the app reports them

    func windowDidOpen(_ window: ExtensionHostWindow) {
        guard let profile = profiles[window.extensionProfileId] else { return }
        profile.controller.didOpenWindow(profile.windowAdapter(for: window))
    }

    func windowDidClose(_ window: ExtensionHostWindow) {
        guard let profile = profiles[window.extensionProfileId] else { return }
        profile.controller.didCloseWindow(profile.windowAdapter(for: window))
        profile.forgetWindow(window)
    }

    func windowDidBecomeFocused(_ window: ExtensionHostWindow) {
        guard let profile = profiles[window.extensionProfileId] else { return }
        profile.controller.didFocusWindow(profile.windowAdapter(for: window))
    }

    func tabDidOpen(_ tab: ExtensionHostTab) {
        guard let profile = profile(forTab: tab) else { return }
        profile.controller.didOpenTab(profile.tabAdapter(for: tab))
    }

    func tabDidClose(_ tab: ExtensionHostTab, windowIsClosing: Bool, profileId: String) {
        guard let profile = profiles[profileId], let adapter = profile.existingTabAdapter(for: tab) else { return }
        profile.controller.didCloseTab(adapter, windowIsClosing: windowIsClosing)
        profile.forgetTab(tab)
    }

    func tabDidClose(_ tab: ExtensionHostTab, windowIsClosing: Bool) {
        for profile in profiles.values where profile.existingTabAdapter(for: tab) != nil {
            tabDidClose(tab, windowIsClosing: windowIsClosing, profileId: profile.profileId)
        }
    }

    func tabDidActivate(_ tab: ExtensionHostTab, previous: ExtensionHostTab?) {
        guard let profile = profile(forTab: tab) else { return }
        let previousAdapter = previous.flatMap { profile.existingTabAdapter(for: $0) }
        profile.controller.didActivateTab(profile.tabAdapter(for: tab), previousActiveTab: previousAdapter)
        host?.extensionsDidChange(profileId: profile.profileId)
    }

    func tabDidChange(_ tab: ExtensionHostTab, _ change: EngineExtensionTabChange) {
        guard let profile = profile(forTab: tab), let adapter = profile.existingTabAdapter(for: tab) else { return }
        var properties: WKWebExtension.TabChangedProperties = []
        if change.contains(.url) { properties.insert(.URL) }
        if change.contains(.title) { properties.insert(.title) }
        if change.contains(.loading) { properties.insert(.loading) }
        if change.contains(.pinned) { properties.insert(.pinned) }
        profile.controller.didChangeTabProperties(properties, for: adapter)
    }

    private func profile(forTab tab: ExtensionHostTab) -> WebKitExtensionProfile? {
        guard let window = tab.extensionWindow else { return nil }
        return profiles[window.extensionProfileId]
    }
}

// MARK: - What the controller asks

@available(macOS 15.4, *)
extension WebKitExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let profile = profile(for: controller), let host else { return [] }
        return host.extensionWindows(profileId: profile.profileId).map { profile.windowAdapter(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let profile = profile(for: controller),
              let front = host?.extensionWindows(profileId: profile.profileId).first,
              front.extensionNSWindow?.isMainWindow == true
        else { return nil }
        return profile.windowAdapter(for: front)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let profile = profile(for: controller) else { return nil }
        let requested = (configuration.window as? WebKitExtensionWindowAdapter)?.hostWindow
        guard let window = requested ?? host?.extensionWindows(profileId: profile.profileId).first else {
            let urls = configuration.url.map { [$0] } ?? []
            return host?.extensionOpenWindow(profileId: profile.profileId, urls: urls, focused: true)?
                .extensionActiveTab.map { profile.tabAdapter(for: $0) }
        }
        guard let tab = window.extensionOpenTab(url: configuration.url, active: configuration.shouldBeActive) else { return nil }
        if configuration.shouldBePinned { tab.extensionSetPinned(true) }
        return profile.tabAdapter(for: tab)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // Extensions never open private windows: those carry no extensions.
        guard let profile = profile(for: controller), !configuration.shouldBePrivate,
              let window = host?.extensionOpenWindow(profileId: profile.profileId, urls: configuration.tabURLs, focused: configuration.shouldBeFocused)
        else { return nil }
        return profile.windowAdapter(for: window)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let profile = profile(for: controller), let url = extensionContext.optionsPageURL else { return }
        openInNewTab(url, profileId: profile.profileId)
    }

    /// `permissions.request()` for API permissions. Only ones the manifest
    /// itself names can be granted -- an extension cannot talk its way into
    /// something it never declared -- and a yes is remembered like the
    /// install-time consent.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        guard let profile = profile(for: controller) else { return ([], nil) }
        let found = extensionContext.webExtension
        let declared = found.requestedPermissions.union(found.optionalPermissions)
        let asked = permissions.intersection(declared)
        guard !asked.isEmpty else { return ([], nil) }
        let grants = WebExtensionGrants.make(permissions: asked.map(\.rawValue), matchPatterns: [])
        let name = found.displayName ?? "An extension"
        guard await consent(title: "“\(name)” asks for more access", grants: grants, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Allow") else {
            return ([], nil)
        }
        remember(grants, for: extensionContext.uniqueIdentifier, in: profile)
        return (asked, nil)
    }

    /// WebKit asks this the way Safari does: whenever an extension reaches
    /// for a page it has no host access to -- listing tabs, scripting one --
    /// often with nobody having touched anything. Chrome never asks there:
    /// an extension has the sites it was installed with, the page it was
    /// invoked on (activeTab, via shouldGrantPermissionsOnUserGesture), and
    /// what it asked for through permissions.request. So neither does this.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        ([], nil)
    }

    /// `permissions.request({origins})`: site access beyond the install's.
    /// Only patterns the manifest declares (required or optional) are
    /// grantable.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        guard let profile = profile(for: controller) else { return ([], nil) }
        let found = extensionContext.webExtension
        let declared = found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns)
        let asked = matchPatterns.filter { pattern in declared.contains { $0.matches(pattern) } }
        guard !asked.isEmpty else { return ([], nil) }
        let grants = WebExtensionGrants.make(permissions: [], matchPatterns: asked.map(\.string))
        let name = found.displayName ?? "An extension"
        guard await consent(title: "“\(name)” asks for more access", grants: grants, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Allow") else {
            return ([], nil)
        }
        remember(grants, for: extensionContext.uniqueIdentifier, in: profile)
        return (asked, nil)
    }

    private func remember(_ grants: [String], for id: String, in profile: WebKitExtensionProfile) {
        profile.update(id) { $0.grants = Array(Set($0.grants).union(grants)).sorted() }
        profile.save()
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        guard let profile = profile(for: controller) else { return }
        host?.extensionsDidChange(profileId: profile.profileId)
    }

    /// WebKit's own popover, hung from the extension's pinned button in the
    /// window it was pressed in, or from the extensions button.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        guard let profile = profile(for: controller), let popover = action.popupPopover else { return }
        let window = profile.actionWindow ?? host?.extensionWindows(profileId: profile.profileId).first
        let anchor = window?.extensionPopupAnchor(forExtension: context.uniqueIdentifier)
        profile.shownPopover = popover
        profile.shownPopoverExtensionId = context.uniqueIdentifier
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = window?.extensionNSWindow?.contentView {
            let spot = NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
    }
}
