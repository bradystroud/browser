import Foundation

/// Owns the shared threat (phishing/malware) BlockList and coordinates
/// pushing the current threat-warning snapshot -- the shared threat-domain
/// list plus every existing profile's ThreatWarningSettings -- down to the
/// bridge (BRWThreatList), where BRWClientHandler::OnBeforeResourceLoad
/// reads it on CEF's IO thread. Deliberately parallel to, and independent
/// of, ContentBlockerCoordinator (the ad/tracker case): same "load once at
/// launch, re-push on every settings change" shape, but its own BlockList
/// instance and its own settings type, since a threat hit gets different
/// treatment than an ad hit (browser-12m.6) -- see BRWThreatList.mm's
/// class-level comment for the bridge-side threading model this feeds
/// into.
///
/// Also registers the Swift-side interstitial-page builder (see
/// BRWThreatList.h) -- the one piece of this feature that needs the bridge
/// to call *back into* Swift, since building the warning page is pure
/// Swift/Foundation code (ThreatWarningPageRenderer, BlockListCore) that
/// C++ can't import directly.
final class ThreatListCoordinator {
    static let shared = ThreatListCoordinator()

    private let threatList = BlockList()
    private var profileChangeObserver: NSObjectProtocol?

    private init() {
        threatList.load(starterThreatListText)
    }

    /// Call once at launch, after the engine has initialized (see
    /// CEFEngineAdapter.swift, alongside ContentBlockerCoordinator.start())
    /// -- registers the interstitial-page builder, pushes the initial
    /// snapshot, and starts observing profile-list changes so the bridge
    /// always has a settings entry for every profile that currently
    /// exists.
    func start() {
        ActiveEngine.setThreatInterstitialBuilder { host, originalURL in
            ThreatWarningPageRenderer.dataURL(host: host, originalURL: originalURL)
        }
        pushSnapshot()
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pushSnapshot()
        }
    }

    /// The given profile's current threat-warning settings (default:
    /// enabled, if never explicitly saved before).
    func settings(forProfileName profileName: String) -> ThreatWarningSettings {
        ThreatWarningSettingsStore.load(forProfileName: profileName)
    }

    /// Call after changing a profile's ThreatWarningSettings (see
    /// PrivacyPaneController) -- persists to disk and pushes the updated
    /// snapshot to the bridge immediately.
    func updateSettings(_ settings: ThreatWarningSettings, forProfileName profileName: String) {
        ThreatWarningSettingsStore.save(settings, forProfileName: profileName)
        pushSnapshot()
    }

    private func pushSnapshot() {
        let domains = threatList.allDomains()

        var engineSettings: [String: EngineProfileThreatSettings] = [:]
        for profile in ProfileManager.shared.profiles {
            let settings = ThreatWarningSettingsStore.load(forProfileName: profile.name)
            engineSettings[profile.name] = EngineProfileThreatSettings(enabled: settings.isEnabled)
        }
        // "private" is the fixed profile_name every private-browsing
        // window's engine-side handler is constructed with (see the CEF
        // adapter's -initPrivateWithHostView:initialURL: for the CEF
        // specifics) -- there's no real Profile to load ThreatWarningSettings
        // for, but a private window still gets the warning (per
        // browser-12m.1's private-window scope: "Private windows: enabled
        // too").
        engineSettings["private"] = EngineProfileThreatSettings(enabled: true)

        ActiveEngine.updateThreatBlocking(domains: domains, profileSettings: engineSettings)
    }
}
