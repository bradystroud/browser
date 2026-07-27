import AppKit

/// Central entry point for routing an incoming link (from a kAEGetURL Apple
/// Event, or an already-running app) to the right profile's window, per
/// docs/plans/2026-07-27-browser-plan.md's M2 routing action.
final class RoutingCoordinator {
    static let shared = RoutingCoordinator()

    /// Flips true once BRWEngine + ProfileManager + WindowManager are ready
    /// to accept new windows/tabs (set from AppDelegate.applicationDidFinish
    /// Launching, after BRWEngine.initialize succeeds). A link click can
    /// cold-launch the app, and macOS delivers the kAEGetURL event at or
    /// before launch -- often before that initialization has run. Any
    /// route(url:) call before `markReady()` is queued here rather than
    /// dropped or acted on against a not-yet-initialized engine.
    private(set) var isReady = false
    private var pendingRoutes: [(url: String, sourceBundleId: String?)] = []

    /// True if a URL was already routed before `markReady()` -- i.e. this was
    /// a cold launch via a link click, per Apple's documented delivery
    /// ordering for the launch-time kAEGetURL event (registered in
    /// applicationWillFinishLaunching so it's caught here). AppDelegate uses
    /// this to skip opening its usual "default window" on launch, so a
    /// routed cold launch doesn't also pop an unrelated blank/default window.
    var hasPendingRoutes: Bool { !pendingRoutes.isEmpty }

    private init() {}

    func markReady() {
        isReady = true
        let queued = pendingRoutes
        pendingRoutes.removeAll()
        for pending in queued {
            route(url: pending.url, sourceBundleId: pending.sourceBundleId)
        }
    }

    /// Resolves the target profile via RuleMatcher and opens `url` there.
    /// `sourceBundleId` is nil when the sender PID couldn't be resolved (see
    /// SourceAppResolver) -- that's treated as "no source" for matching
    /// purposes, per docs/research/2026-07-27-link-routing-macos.md.
    func route(url: String, sourceBundleId: String?) {
        guard isReady else {
            pendingRoutes.append((url, sourceBundleId))
            return
        }

        let store = RoutingRulesStore.shared
        let context = RoutingContext(url: url, sourceBundleId: sourceBundleId)
        let profileId = RuleMatcher.resolveProfileId(
            for: context,
            rules: store.rules,
            defaultProfileId: store.defaultProfileId
        )

        let profile = ProfileManager.shared.profile(id: profileId)
            ?? ProfileManager.shared.profileOrCreate(named: ProfileManager.defaultProfileName)

        openURL(url, in: profile)
    }

    /// Opens `url` as a new tab in the frontmost existing window of
    /// `profile`, or a new window for that profile if none is currently open.
    private func openURL(_ url: String, in profile: Profile) {
        if let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            controller.addTab(url: url, makeActive: true)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
