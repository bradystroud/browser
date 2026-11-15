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

    /// The folder WebKit loads: for a store extension, WebKit's prepared
    /// copy beside the untouched package, built or brought up to date off
    /// the main thread (WebKitExtensionInstaller.webKitFolder). A
    /// developer's unpacked folder is never written to or copied: it loads
    /// as it is, and the log says when it asks for an API the layer would
    /// have supplied.
    func preparedFolder(for record: InstalledWebExtension) async -> URL {
        let folder = resourceFolder(for: record)
        switch record.source {
        case .webStore:
            let id = record.id
            let extensions = directory
            return await Task.detached(priority: .userInitiated) {
                WebKitExtensionInstaller.webKitFolder(forPackage: folder, id: id, in: extensions)
            }.value
        case .unpacked:
            if ChromeExtensionCompatibility.isNeeded(folder: folder) {
                NSLog("Browser: unpacked extension %@ would get the Chrome compatibility layer (%@, or action.openPopup from a framed page), which is only added to Web Store installs",
                      record.id, ChromeExtensionCompatibility.suppliedPermissions.sorted().joined(separator: " or "))
            }
        }
        return folder
    }

    /// A message already on the list is not added again: WebKit reports
    /// every error the context has each time the list changes.
    @discardableResult
    func noteError(_ text: String, for id: String) -> Bool {
        guard errors[id]?.contains(text) != true else { return false }
        errors[id, default: []].append(text)
        errors[id] = Array(errors[id]!.suffix(20))
        return true
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
    ///
    /// A tab that may not run extensions (an agent's page, see
    /// ExtensionIsolationPolicy) gets `base` back untouched: no controller,
    /// so no content scripts and no extension API, and no extension's page
    /// configuration, so its pages cannot load in it.
    func configuration(for base: WKWebViewConfiguration, profileId: String, initialURL: String, runsExtensions: Bool) -> WKWebViewConfiguration {
        guard runsExtensions, let profile = profile(for: profileId) else { return base }
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
        ExtensionSettingsHost.provider?.forget(profileId: profileId)
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

    /// An extension installed before this app recorded a permission it
    /// implements itself (`privacy`) declares it but has no answer for it.
    /// It is asked once, as the extension loads; the answer is recorded --
    /// a refusal in `declinedGrants`, so the next load does not ask again
    /// (a manual Reload does). Either way the extension then runs: these
    /// permissions only gate what the app itself offers it.
    @MainActor
    private func askForUnaskedAppPermissions(_ found: WKWebExtension, id: String, in profile: WebKitExtensionProfile) async {
        guard let record = profile.record(id) else { return }
        let unasked = WebExtensionGrants.unasked(Self.grants(for: found), in: record).filter {
            WebExtensionGrants.onlyAppImplemented([$0])
        }
        guard !unasked.isEmpty, profile.busy.insert(id).inserted else { return }
        defer { profile.busy.remove(id) }
        let name = found.displayName ?? record.name
        let allowed = await consent(title: "“\(name)” wants more access", grants: unasked,
                                    icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Allow")
        profile.update(id) {
            if allowed {
                $0.grants = Array(Set($0.grants).union(unasked)).sorted()
            } else {
                $0.declinedGrants = Array(Set($0.declinedGrants ?? []).union(unasked)).sorted()
            }
        }
        profile.save()
    }

    /// A store extension still on the list whose package folder is gone --
    /// deleted from under the app -- is downloaded again through the same
    /// verified path as an install, and keeps the grants on record: the user
    /// is asked only for what the package now wants beyond them (an
    /// app-implemented permission refused there is recorded as refused, as
    /// at load). When that fails the record stays, the extension shows the
    /// error, and the next launch tries again.
    @MainActor
    private func restorePackage(_ id: String, in profile: WebKitExtensionProfile, because state: WebExtensionsFolder.PackageState) async -> Bool {
        guard let record = profile.record(id), profile.busy.insert(id).inserted else { return false }
        defer { profile.busy.remove(id) }
        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        do {
            try profile.createDirectory()
            let fetched = try await WebKitExtensionInstaller.downloadAndStage(id: id, in: profile.directory)
            staged = fetched
            let found = try await WKWebExtension(resourceBaseURL: fetched)
            let name = found.displayName ?? record.name
            let requested = Self.grants(for: found)
            var declined = Set(record.declinedGrants ?? [])
            let added = WebExtensionGrants.added(requested, beyond: record.grants + declined)
            if !added.isEmpty,
               !(await consent(title: "“\(name)” wants more access", grants: added, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Allow")) {
                guard WebExtensionGrants.onlyAppImplemented(added) else {
                    profile.noteError("Its files are \(state == .missing ? "missing" : "incomplete"), and the version that would replace them asks for access that was refused. Reload it to be asked again.", for: id)
                    host?.extensionsDidChange(profileId: profile.profileId)
                    return false
                }
                declined.formUnion(added)
            }
            guard profile.record(id) != nil else { return false }
            try WebKitExtensionInstaller.replace(profile.storeFolder(for: id), with: fetched)
            staged = nil
            recordContents(of: id, in: profile)
            profile.update(id) {
                $0.name = name
                $0.version = found.version ?? $0.version
                $0.grants = Array(Set($0.grants).union(requested).subtracting(declined)).sorted()
                $0.declinedGrants = declined.isEmpty ? nil : declined.sorted()
            }
            profile.save()
            NSLog("Browser: downloaded extension %@ again (%@ package, version %@)", id, "\(state)", found.version ?? "?")
            return true
        } catch {
            NSLog("Browser: extension %@ (%@ package) could not be downloaded again: %@", id, "\(state)", error.localizedDescription)
            profile.noteError("Its files are \(state == .missing ? "missing" : "incomplete") and could not be downloaded again (\(error.localizedDescription)). Browser tries again at the next launch.", for: id)
            host?.extensionsDidChange(profileId: profile.profileId)
            return false
        }
    }

    /// Records what a store package holds now (WebExtensionsFolder), so a
    /// later load can tell it is still whole.
    private func recordContents(of id: String, in profile: WebKitExtensionProfile) {
        do {
            try WebExtensionsFolder.recordContents(of: profile.storeFolder(for: id), id: id, in: profile.directory)
        } catch {
            NSLog("Browser: couldn't record the contents of extension %@: %@", id, error.localizedDescription)
        }
    }

    @MainActor @discardableResult
    private func load(_ id: String, in profile: WebKitExtensionProfile) async -> Bool {
        guard var record = profile.record(id), profile.contexts[id] == nil else { return false }
        // A package missing or no longer matching its record is fetched again
        // and not loaded without it. One with no record yet (unpacked by an
        // older version) is loaded as found and recorded then, once
        // preparedFolder has put back anything an older layout wrote into it;
        // nothing is downloaded for it.
        let state = WebExtensionsFolder.packageState(of: record, packageFolder: profile.storeFolder(for: id), in: profile.directory)
        if state == .missing || state == .damaged {
            guard await restorePackage(id, in: profile, because: state), let restored = profile.record(id) else { return false }
            record = restored
        }
        do {
            let folder = await profile.preparedFolder(for: record)
            if state == .unverified { recordContents(of: id, in: profile) }
            let found = try await WKWebExtension(resourceBaseURL: folder)
            guard profile.contexts[id] == nil, profile.record(id) != nil else { return false }
            await askForUnaskedAppPermissions(found, id: id, in: profile)
            guard profile.contexts[id] == nil, let current = profile.record(id) else { return false }
            try start(found, record: current, in: profile)
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
        // WebKit does not disconnect a context's native ports when it unloads
        // it, so the hosts would outlive the extension.
        MainActor.assumeIsolated { WebKitNativeMessaging.stopHosts(for: context) }
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
            for error in context.errors where profile.noteError(error.localizedDescription, for: id) {
                let nsError = error as NSError
                NSLog("Browser: extension %@ reported an error (%@ %ld): %@",
                      id, nsError.domain, nsError.code, nsError.localizedDescription)
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
        recordContents(of: id, in: profile)
        let record = InstalledWebExtension(id: id, source: .webStore, name: name, version: found.version ?? "0", grants: grants)
        profile.list.extensions.append(record)
        profile.save()
        let installed = try await WKWebExtension(resourceBaseURL: await profile.preparedFolder(for: record))
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
        guard FileManager.default.fileExists(atPath: profile.resourceFolder(for: record).appendingPathComponent("manifest.json").path) else {
            throw WebKitExtensionError.noManifest
        }
        let folder = await profile.preparedFolder(for: record)
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let name = found.displayName ?? record.name
        let requested = Self.grants(for: found)
        // A Reload asks again for what was refused before.
        let added = WebExtensionGrants.added(requested, beyond: record.grants)
        var declined = Set(record.declinedGrants ?? [])
        if !added.isEmpty {
            let allowed = await consent(title: "“\(name)” wants more access", grants: added, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Allow")
            if allowed {
                declined.subtract(added)
            } else if WebExtensionGrants.onlyAppImplemented(added) {
                declined.formUnion(added)
            } else {
                throw WebKitExtensionError.cancelled
            }
        }
        unload(id, in: profile)
        profile.errors[id] = nil
        profile.revivals[id] = nil
        profile.update(id) {
            $0.name = name
            $0.version = found.version ?? $0.version
            $0.grants = Array(Set($0.grants).union(requested).subtracting(declined)).sorted()
            $0.declinedGrants = declined.isEmpty ? nil : declined.sorted()
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
            // What it held goes back to the user, as when it is turned off.
            ExtensionSettingsHost.provider?.release(extensionId: id, profileId: profileId)
            profile.list.extensions.removeAll { $0.id == id }
            profile.errors[id] = nil
            profile.save()
            // A developer's own folder is theirs; only a copy this app
            // unpacked is deleted.
            if record.source == .webStore {
                try? FileManager.default.removeItem(at: profile.storeFolder(for: id))
                WebKitExtensionInstaller.removeWebKitCopy(id: id, in: profile.directory)
                WebExtensionsFolder.forgetContents(id: id, in: profile.directory)
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
            // A turned-off extension holds no setting (Chrome's rule); it
            // takes it again, if it wants it, when it next runs.
            ExtensionSettingsHost.provider?.release(extensionId: id, profileId: profileId)
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
            // What was refused before is not asked again by an update.
            var declined = Set(record.declinedGrants ?? [])
            let added = WebExtensionGrants.added(requested, beyond: record.grants + declined)
            if !added.isEmpty {
                let title = "An update to “\(name)” wants more access"
                if !(await consent(title: title, grants: added, icon: found.icon(for: CGSize(width: 64, height: 64)), allow: "Update")) {
                    guard WebExtensionGrants.onlyAppImplemented(added) else { return false }
                    declined.formUnion(added)
                }
            }
            guard profile.record(id) != nil, profiles[profile.profileId] === profile else { return false }
            let wasLoaded = profile.contexts[id] != nil
            unload(id, in: profile)
            try WebKitExtensionInstaller.replace(profile.storeFolder(for: id), with: staged)
            recordContents(of: id, in: profile)
                profile.update(id) {
                $0.name = name
                $0.version = found.version ?? offered.description
                $0.grants = Array(Set($0.grants).union(requested).subtracting(declined)).sorted()
                $0.declinedGrants = declined.isEmpty ? nil : declined.sorted()
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
    /// WebKit lists only the permissions it knows, so the ones this app
    /// implements itself (`privacy`) are read from the manifest.
    static func grants(for found: WKWebExtension) -> [String] {
        WebExtensionGrants.make(
            permissions: found.requestedPermissions.map(\.rawValue)
                + WebExtensionGrants.appImplementedPermissions(declaredIn: found.manifest),
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
    /// The calling extension's profile, and whether the user granted it
    /// `privacy` -- which WebKit has no permission for, so the grant is read
    /// from the app's own record of what was agreed to.
    private func settingsCaller(_ controller: WKWebExtensionController, _ context: WKWebExtensionContext) -> (profileId: String?, privacyGranted: Bool) {
        guard let profile = profile(for: controller) else { return (nil, false) }
        let granted = profile.record(context.uniqueIdentifier)?.grants.contains("perm:privacy") ?? false
        return (profile.profileId, granted)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        let caller = settingsCaller(controller, extensionContext)
        return try await WebKitNativeMessaging.sendMessage(message, toHost: applicationIdentifier, from: extensionContext,
                                                           profileId: caller.profileId, privacyGranted: caller.privacyGranted)
    }

    /// The completion-handler form, not `async`: an async method only starts
    /// once WebKit's call has returned, and a message the extension posts
    /// straight after `connectNative` (iCloud Passwords' first one) reaches
    /// a port with no handler yet and is dropped. Here the handler is in
    /// place before WebKit's call returns.
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        do {
            let caller = settingsCaller(controller, extensionContext)
            try WebKitNativeMessaging.connect(port, from: extensionContext, profileId: caller.profileId, privacyGranted: caller.privacyGranted)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

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

    /// `window.open` of an extension's own page from a frame of that same
    /// extension inside a web page (`WebKitTab`'s `createWebViewWith`).
    /// Returns false when `url` is not such a page, and the caller's usual
    /// rules apply.
    @MainActor
    func openPageWindow(_ url: URL, openerOrigin: String?, from webView: WKWebView, features: WKWindowFeatures) -> Bool {
        guard url.scheme == Self.pageScheme, let id = url.host, openerOrigin == "\(Self.pageScheme)://\(id)" else { return false }
        guard let controller = webView.configuration.webExtensionController,
              let profile = profile(for: controller), let context = profile.contexts[id],
              let configuration = context.webViewConfiguration else {
            NSLog("Browser: refused a window for extension %@: it is not running for this tab's profile", id)
            return true
        }
        configuration.applicationNameForUserAgent = webView.configuration.applicationNameForUserAgent
        WebKitExtensionPageWindow.show(url, configuration: configuration, features: features,
                                       title: context.webExtension.displayName ?? id, over: webView.window)
        return true
    }

    /// WebKit's own popover, hung from the extension's pinned button in the
    /// window it was pressed in, or from the extensions button.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        guard let profile = profile(for: controller), let popover = action.popupPopover else { return }
        // The window of the tab WebKit opened the popup for (the toolbar
        // press, or `action.openPopup()` for a window), not the window of
        // the last toolbar press: an extension that opens its popup from a
        // page must get it in that page's window.
        let tabWindow = (action.associatedTab as? WebKitExtensionTabAdapter)?.hostTab?.extensionWindow
        let window = tabWindow ?? profile.actionWindow ?? host?.extensionWindows(profileId: profile.profileId).first
        let anchor = window?.extensionPopupAnchor(forExtension: context.uniqueIdentifier)
        profile.shownPopover = popover
        profile.shownPopoverExtensionId = context.uniqueIdentifier
        if let anchor, anchor.window?.isVisible == true {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = window?.extensionNSWindow?.contentView, content.window?.isVisible == true {
            let spot = NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
        }
        // A popup nobody can see or dismiss must not stay open: its page
        // keeps running, and an extension waiting on it (iCloud Passwords
        // waits for a pairing code it has already asked for) only learns the
        // popup is gone from its port closing. Closing it closes the page.
        if !popover.isShown {
            NSLog("Browser: closed extension %@'s popup: no visible window to show it in", context.uniqueIdentifier)
            action.closePopup()
            if profile.shownPopover === popover {
                profile.shownPopover = nil
                profile.shownPopoverExtensionId = nil
            }
        }
    }
}
