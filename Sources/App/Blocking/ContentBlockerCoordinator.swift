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
    func settings(forProfileName profileName: String) -> BlockingSettings {
        BlockingSettingsStore.load(forProfileName: profileName)
    }

    /// Call after changing a profile's BlockingSettings (see
    /// PrivacyPaneController) -- persists to disk and pushes the updated
    /// snapshot to the bridge immediately. Both steps are this
    /// coordinator's job; callers only deal in BlockingSettings values.
    func updateSettings(_ settings: BlockingSettings, forProfileName profileName: String) {
        BlockingSettingsStore.save(settings, forProfileName: profileName)
        pushSnapshot()
    }

    private func pushSnapshot() {
        let domains = blockList.allDomains()

        var bridgeSettings: [String: BRWProfileBlockingSettings] = [:]
        for profile in ProfileManager.shared.profiles {
            let settings = BlockingSettingsStore.load(forProfileName: profile.name)
            bridgeSettings[profile.name] = BRWProfileBlockingSettings(
                enabled: settings.isEnabled,
                allowlistedHosts: settings.allowlistedHosts
            )
        }

        BRWContentBlocker.update(withBlockedDomains: domains, profileSettings: bridgeSettings)
    }
}
