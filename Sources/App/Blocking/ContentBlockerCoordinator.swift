import Foundation

/// Owns the shared BlockList (parsed once at launch from the bundled
/// starter list) and coordinates pushing the current content-blocking
/// snapshot -- the shared blocked-domain list plus every existing
/// profile's BlockingSettings -- down to the bridge (BRWContentBlocker),
/// where BRWClientHandler::OnBeforeResourceLoad reads it on CEF's IO
/// thread. See BRWContentBlocker.mm's class-level comment for the actual
/// atomic-swap threading model this feeds into; this class's only job is
/// knowing *when* to push a fresh snapshot (launch, and any settings
/// change) -- it is never itself called from the IO thread.
final class ContentBlockerCoordinator {
    static let shared = ContentBlockerCoordinator()

    private let blockList = BlockList()
    private var profileChangeObserver: NSObjectProtocol?

    private init() {
        blockList.loadStarterList()
    }

    /// Call once at launch, after the engine has initialized (see
    /// CEFEngineAdapter.swift) -- pushes the initial snapshot and starts
    /// observing profile-list changes (new/renamed/deleted profiles) so
    /// the bridge always has a settings entry for every profile that
    /// currently exists.
    func start() {
        pushSnapshot()
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pushSnapshot()
        }
    }

    /// The given profile's current blocking settings (default: enabled, no
    /// allowlist, if never explicitly saved before).
    func settings(forProfileId profileId: String) -> BlockingSettings {
        BlockingSettingsStore.load(forProfileId: profileId)
    }

    /// Call after changing a profile's BlockingSettings (see
    /// PrivacyPaneController) -- persists to disk and pushes the updated
    /// snapshot to the bridge immediately. Both steps are this
    /// coordinator's job; callers only deal in BlockingSettings values.
    func updateSettings(_ settings: BlockingSettings, forProfileId profileId: String) {
        BlockingSettingsStore.save(settings, forProfileId: profileId)
        pushSnapshot()
    }

    private func pushSnapshot() {
        let domains = blockList.allDomains()

        // Keyed by profile *name* here, deliberately -- this dictionary is
        // read engine-side by BRWClientHandler's own name-keyed
        // profile_name_ (a separate, in-memory-only mechanism from the
        // id-keyed on-disk BlockingSettingsStore lookup just above; see
        // BRWBrowser.h's initializer doc comment for why the two aren't
        // conflated). A rename just means this rebuilds under the new name
        // moments later via the .profileManagerDidChange observer below --
        // nothing here needs to survive across a rename the way the actual
        // BlockingSettings.disk storage does.
        var engineSettings: [String: EngineProfileBlockingSettings] = [:]
        for profile in ProfileManager.shared.profiles {
            let settings = BlockingSettingsStore.load(forProfileId: profile.id)
            engineSettings[profile.name] = EngineProfileBlockingSettings(
                enabled: settings.isEnabled,
                allowlistedHosts: settings.allowlistedHosts
            )
        }
        // "private" is the fixed profile_name every private-browsing window's
        // engine-side handler is constructed with (see the CEF adapter's
        // -initPrivateWithHostView:initialURL: for the CEF specifics) --
        // there's no real Profile to load a BlockingSettings for, but
        // without an entry here the engine finds no snapshot for that name
        // and silently never blocks anything for private windows.
        // Always-enabled, no per-profile allowlist: a private window has no
        // settings UI of its own to manage one from.
        engineSettings["private"] = EngineProfileBlockingSettings(enabled: true, allowlistedHosts: [])

        ActiveEngine.updateContentBlocking(domains: domains, profileSettings: engineSettings)
    }
}
