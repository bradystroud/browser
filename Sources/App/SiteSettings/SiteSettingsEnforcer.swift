import AppKit

/// Applies the per-site settings that need to happen *to a page* rather than
/// to a store (browser-06d). Today that is one setting, auto-mute: a tab
/// that lands on a host the user asked to keep quiet is muted as soon as it
/// gets there, and unmuted again when it leaves.
///
/// A TabLifecycleObserver, not a timer -- the two moments that matter (the
/// main-frame URL changed, the load finished) are both lifecycle events
/// already, so there is nothing here to poll for (see TabLifecycleCenter).
/// Registered from AppDelegate.applicationDidFinishLaunching by touching
/// `shared`, for the same reason ShortcutsOverlayController is: the observer
/// has to exist before the first page loads, not from the first time a menu
/// action happens to mention this type.
///
/// Private windows are skipped entirely. A private tab's audio is not worth
/// reaching into a persisted, per-profile store for, and the private
/// pseudo-profile is shared by every private window (see
/// ContentBlockerToolbarController's doc comment), so honouring a stored
/// setting there would be applying one profile's choice inside a window that
/// is supposed to carry none of it.
final class SiteSettingsEnforcer: NSObject, TabLifecycleObserver {
    static let shared = SiteSettingsEnforcer()

    /// Tabs this class muted, so leaving an auto-muted site can unmute the
    /// tab again without ever clobbering a mute the *user* set by hand on
    /// the tab strip. Identity only -- nothing here keeps a Tab alive.
    private var autoMutedTabs: Set<ObjectIdentifier> = []

    private override init() {
        super.init()
        TabLifecycleCenter.shared.addObserver(self)
        // Piggy-backs on the one touch of this singleton AppDelegate already
        // makes, so the sheet's screenshot flag needs no launch wiring of its
        // own. A no-op unless that flag was passed.
        SiteSettingsSheetController.shared.registerAutoPresentIfRequested()
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        switch event {
        case .navigated, .finishedLoading:
            apply(to: tab)
        case .closed:
            autoMutedTabs.remove(ObjectIdentifier(tab))
        case .opened, .becameActive:
            break
        }
    }

    /// Re-applies one host's settings to every open tab currently showing it
    /// in that profile -- what makes the sheet's switch take effect on the
    /// page behind it immediately, instead of at the next navigation.
    func applySettingsChanged(host: String, profileId: String) {
        for controller in WindowManager.shared.windowControllers where controller.profile.id == profileId {
            for tab in controller.tabs where SiteIdentity.host(forURLString: tab.urlString) == host.lowercased() {
                apply(to: tab)
            }
        }
    }

    private func apply(to tab: Tab) {
        guard !tab.isPrivate,
              let profile = ProfileManager.shared.profile(id: tab.profileId)
        else { return }

        let host = SiteIdentity.host(forURLString: tab.urlString)
        let wantsMute = host.map {
            SiteSettingsStoreManager.shared.store(for: profile).record(for: $0).autoMute
        } ?? false

        let key = ObjectIdentifier(tab)
        if wantsMute {
            if !tab.isMuted {
                // Tab exposes only a toggle, deliberately (it is the single
                // place SetAudioMuted is called, so isMuted cannot drift) --
                // the guard above is what turns it into a set.
                tab.toggleMuted()
            }
            autoMutedTabs.insert(key)
        } else if autoMutedTabs.contains(key) {
            if tab.isMuted {
                tab.toggleMuted()
            }
            autoMutedTabs.remove(key)
        }
    }
}
