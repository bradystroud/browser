import AppKit

/// An engine's extension runtime that runs the install list another
/// engine's manager owns. Chromium's in CEF tabs is one: WebKit's manager
/// installs, updates and removes, and the follower runs the same list.
protocol FollowerExtensionRuntime: AnyObject {
    var engine: EngineChoice { get }
    /// Where the owner keeps each profile's install list and packages. Set
    /// before the engine starts.
    func setStorageDirectory(_ directory: @escaping (String) -> URL?)
    /// The user's switch for this runtime. Set before the engine starts;
    /// fixed for the session. Off, the runtime runs nothing.
    func setTurnedOn(_ on: Bool)
    /// The switch as the next launch will read it, for the consent note.
    func setNextLaunchSetting(_ isOn: @escaping () -> Bool)
    /// Whether it runs anything in this session. Off, the owner keeps the
    /// toolbar and the follower only reports state.
    var runsThisSession: Bool { get }
    /// What the consent for installing or updating the extension with
    /// `manifest` has to add, because this runtime would run it too (or
    /// would refuse to). Nil when it has nothing to say.
    func consentNote(manifest: [String: Any]) -> String?
    /// `installList` is the owner, for what the follower learns about an
    /// installed extension and has to keep on its record.
    func attach(host: ExtensionHost, installList: EngineExtensionInstallList?)
    /// The owner changed the profile's list or something on it.
    func installListDidChange(profileId: String)
    func status(extensionId: String, profileId: String) -> EngineExtensionRuntimeStatus?
    /// The button for a tab of this engine. `base` is the owner's button
    /// with no tab, for the label and icon.
    func action(extensionId: String, profileId: String, base: EngineExtensionAction?) -> EngineExtensionAction?
    /// The button was pressed over a tab of this engine. False when this
    /// runtime did nothing with it.
    func performAction(extensionId: String, window: ExtensionHostWindow) -> Bool
    func owns(_ tab: EngineTab) -> Bool
    /// Whether every tab of this engine in the profile gets the profile's
    /// extensions in this session, with no way to keep one tab out.
    func extensionsReachEveryTab(profileId: String) -> Bool
    /// Asks the store for what the follower still needs (see
    /// EngineExtensionRuntimeStatus.isWaitingForKey).
    @MainActor func refreshFromStore(profileId: String) async
    /// See EngineExtensionManager.refreshRuntimeStatus.
    func refreshRuntimeStatus(profileId: String)
    func extensionsStillRunningAfterRemoval(profileId: String) -> [EngineExtensionStillRunning]
    /// The user approved what the approval sheet listed for the extension.
    @discardableResult
    func approveGrants(_ grants: [String], extensionId: String, profileId: String) -> Bool
    /// Consents that carried this follower's note were accepted for the
    /// extension `extensionId`, each showing one of `manifests`.
    func consentWasAccepted(manifests: [[String: Any]], extensionId: String, profileId: String)
    /// Ids and store versions on the profile's list, read now.
    func listedVersions(profileId: String) -> [String: String]
}

/// The one `EngineExtensionManager` the UI sees (`Engines.extensions`): the
/// owner's (WebKit's, which holds the install list and runs it in WebKit
/// tabs), with every follower runtime told about each change and its state
/// added to the summaries. Toolbar buttons go to the runtime of the tab
/// they are pressed over.
final class CombinedExtensionManager: EngineExtensionManager, ExtensionHost {
    private static var made: CombinedExtensionManager?

    /// Nil when there is no owner: then there is no install list, and no
    /// follower runs anything either.
    static func wrapping(_ owner: EngineExtensionManager?) -> EngineExtensionManager? {
        guard let owner else { return nil }
        if let made, made.owner === owner { return made }
        let combined = CombinedExtensionManager(owner: owner)
        made = combined
        return combined
    }

    let owner: EngineExtensionManager
    private weak var host: ExtensionHost?

    private init(owner: EngineExtensionManager) {
        self.owner = owner
    }

    private var followers: [FollowerExtensionRuntime] {
        EngineChoice.allCases.compactMap { Engines.engine($0).extensionRuntime }
    }

    private func follower(for tab: ExtensionHostTab?) -> FollowerExtensionRuntime? {
        guard let engineTab = tab?.extensionEngineTab else { return nil }
        return followers.first { $0.runsThisSession && $0.owns(engineTab) }
    }

    /// The consent capture of the operation running in this task (and the
    /// tasks it awaits). Another operation running at the same time has its
    /// own, so one extension's consent never counts for another.
    private final class ConsentCapture {
        let profileId: String
        /// The extension the operation acts on, when it names one.
        let extensionId: String?
        /// Each accepted sheet's manifest, by the extension it was shown for.
        var manifests: [String: [[String: Any]]] = [:]
        init(profileId: String, extensionId: String?) {
            self.profileId = profileId
            self.extensionId = extensionId
        }

        /// The manifest's own key names its extension; otherwise only an
        /// operation on one named extension can say whose sheet it was.
        func record(_ manifest: [String: Any]) {
            let id = (manifest["key"] as? String).flatMap(ChromeExtensionID.from(manifestKey:)) ?? extensionId
            guard let id else { return }
            manifests[id, default: []].append(manifest)
        }
    }

    @TaskLocal private static var consentCapture: ConsentCapture?

    /// Runs an install, update or reload. Each consent sheet the user
    /// accepted that carried follower notes approves, for the extension it
    /// was shown for and only if the operation changed that extension, the
    /// grants that sheet listed.
    @MainActor private func capturingConsent<T>(profileId: String, extensionId: String?,
                                                _ operation: () async throws -> T) async rethrows -> T {
        let runtimes = followers
        let before = runtimes.first?.listedVersions(profileId: profileId) ?? [:]
        let capture = ConsentCapture(profileId: profileId, extensionId: extensionId)
        let result = try await Self.$consentCapture.withValue(capture) { try await operation() }
        guard !capture.manifests.isEmpty else { return result }
        let after = runtimes.first?.listedVersions(profileId: profileId) ?? [:]
        let changed = Set(after.filter { before[$0.key] != $0.value }.map(\.key))
        for (id, manifests) in capture.manifests where changed.contains(id) || id == extensionId {
            runtimes.forEach { $0.consentWasAccepted(manifests: manifests, extensionId: id, profileId: profileId) }
        }
        return result
    }

    /// See FollowerExtensionRuntime.extensionsReachEveryTab.
    func extensionsReachEveryTab(engine: EngineChoice, profileId: String) -> Bool {
        followers.contains { $0.engine == engine && $0.extensionsReachEveryTab(profileId: profileId) }
    }

    // MARK: - EngineExtensionManager

    func activate(host: ExtensionHost, storageDirectory: @escaping (String) -> URL?) {
        self.host = host
        owner.activate(host: self, storageDirectory: storageDirectory)
        let installList = owner as? EngineExtensionInstallList
        followers.forEach { $0.attach(host: self, installList: installList) }
    }

    func loadExtensions(profileId: String) { owner.loadExtensions(profileId: profileId) }
    func unloadProfile(profileId: String) { owner.unloadProfile(profileId: profileId) }

    func extensions(profileId: String) -> [EngineExtensionSummary] {
        let runtimes = followers
        return owner.extensions(profileId: profileId).map { summary in
            var summary = summary
            for runtime in runtimes {
                summary.runtimes[runtime.engine] = runtime.status(extensionId: summary.id, profileId: profileId)
            }
            return summary
        }
    }

    func action(extensionId: String, profileId: String, tab: ExtensionHostTab?) -> EngineExtensionAction? {
        guard let runtime = follower(for: tab) else { return owner.action(extensionId: extensionId, profileId: profileId, tab: tab) }
        return runtime.action(extensionId: extensionId, profileId: profileId,
                              base: owner.action(extensionId: extensionId, profileId: profileId, tab: nil))
    }

    @MainActor func installFromWebStore(_ linkOrID: String, profileId: String) async throws {
        try await capturingConsent(profileId: profileId, extensionId: ChromeExtensionID.find(in: linkOrID)) {
            try await owner.installFromWebStore(linkOrID, profileId: profileId)
        }
    }

    @MainActor func loadUnpacked(folder: URL, profileId: String) async throws {
        try await capturingConsent(profileId: profileId, extensionId: nil) { try await owner.loadUnpacked(folder: folder, profileId: profileId) }
    }

    @MainActor func reload(extensionId: String, profileId: String) async throws {
        try await capturingConsent(profileId: profileId, extensionId: extensionId) {
            try await owner.reload(extensionId: extensionId, profileId: profileId)
        }
        // A reload that changed nothing on the record sends no change; the
        // folder itself may have.
        followers.forEach { $0.refreshRuntimeStatus(profileId: profileId) }
    }

    func remove(extensionId: String, profileId: String) { owner.remove(extensionId: extensionId, profileId: profileId) }

    func setEnabled(_ enabled: Bool, extensionId: String, profileId: String) {
        owner.setEnabled(enabled, extensionId: extensionId, profileId: profileId)
    }

    func setPinned(_ pinned: Bool, extensionId: String, profileId: String) {
        owner.setPinned(pinned, extensionId: extensionId, profileId: profileId)
    }

    func openOptionsPage(extensionId: String, profileId: String) {
        owner.openOptionsPage(extensionId: extensionId, profileId: profileId)
    }

    func performAction(extensionId: String, window: ExtensionHostWindow) {
        if let runtime = follower(for: window.extensionActiveTab),
           runtime.performAction(extensionId: extensionId, window: window) { return }
        owner.performAction(extensionId: extensionId, window: window)
    }

    @MainActor @discardableResult
    func checkForUpdates(profileId: String, force: Bool) async -> Int {
        let updated = await capturingConsent(profileId: profileId, extensionId: nil) {
            await owner.checkForUpdates(profileId: profileId, force: force)
        }
        for runtime in followers { await runtime.refreshFromStore(profileId: profileId) }
        return updated
    }

    func windowDidOpen(_ window: ExtensionHostWindow) { owner.windowDidOpen(window) }
    func windowDidClose(_ window: ExtensionHostWindow) { owner.windowDidClose(window) }
    func windowDidBecomeFocused(_ window: ExtensionHostWindow) { owner.windowDidBecomeFocused(window) }
    func tabDidOpen(_ tab: ExtensionHostTab) { owner.tabDidOpen(tab) }
    func tabDidClose(_ tab: ExtensionHostTab, windowIsClosing: Bool) { owner.tabDidClose(tab, windowIsClosing: windowIsClosing) }
    func tabDidActivate(_ tab: ExtensionHostTab, previous: ExtensionHostTab?) { owner.tabDidActivate(tab, previous: previous) }
    func tabDidChange(_ tab: ExtensionHostTab, _ change: EngineExtensionTabChange) { owner.tabDidChange(tab, change) }

    @discardableResult
    func approveRuntimeGrants(extensionId: String, profileId: String, engine: EngineChoice, grants: [String]) -> Bool {
        followers.first { $0.engine == engine }?.approveGrants(grants, extensionId: extensionId, profileId: profileId) ?? false
    }

    func extensionsStillRunningAfterRemoval(profileId: String) -> [EngineExtensionStillRunning] {
        followers.flatMap { $0.extensionsStillRunningAfterRemoval(profileId: profileId) }
    }

    func refreshRuntimeStatus(profileId: String) {
        followers.forEach { $0.refreshRuntimeStatus(profileId: profileId) }
    }

    // MARK: - ExtensionHost, between the owner and the app

    func extensionWindows(profileId: String) -> [ExtensionHostWindow] {
        host?.extensionWindows(profileId: profileId) ?? []
    }

    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool) -> ExtensionHostWindow? {
        host?.extensionOpenWindow(profileId: profileId, urls: urls, focused: focused)
    }

    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool, engine: EngineChoice?) -> ExtensionHostWindow? {
        host?.extensionOpenWindow(profileId: profileId, urls: urls, focused: focused, engine: engine)
    }

    func extensionPresentPopup(_ request: EngineExtensionPopupRequest) -> Bool {
        host?.extensionPresentPopup(request) ?? false
    }

    @MainActor func extensionConfirm(_ request: ExtensionConsentRequest) async -> Bool {
        guard let host else { return false }
        let notes = request.manifest.map { manifest in followers.compactMap { $0.consentNote(manifest: manifest) } } ?? []
        guard !notes.isEmpty, let manifest = request.manifest else { return await host.extensionConfirm(request) }
        let accepted = await host.extensionConfirm(ExtensionConsentRequest(
            title: request.title, message: ([request.message] + notes).joined(separator: "\n\n"),
            icon: request.icon, allowTitle: request.allowTitle, manifest: request.manifest))
        // The note listed what the followers grant; accepting it approves
        // that, for the extension the operation changes.
        if accepted, let capture = Self.consentCapture { capture.record(manifest) }
        return accepted
    }

    func extensionNotify(_ message: String, profileId: String) {
        host?.extensionNotify(message, profileId: profileId)
    }

    func extensionsDidChange(profileId: String) {
        followers.forEach { $0.installListDidChange(profileId: profileId) }
        host?.extensionsDidChange(profileId: profileId)
    }
}
