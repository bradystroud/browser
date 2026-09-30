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
    ///
    /// Tracking-param stripping (LinkHandlingPreferences.stripTrackingParams,
    /// on by default) and un-shortening (LinkHandlingPreferences.
    /// unshortenLinks, off by default) both happen here, before matching --
    /// a rule written against a bare URL should keep matching regardless of
    /// whatever ?utm_source=... a shared link happened to be decorated
    /// with, and un-shortening a t.co/bit.ly link is what makes a domain-
    /// based rule match at all for a link shared in Slack (browser-ymx).
    func route(url: String, sourceBundleId: String?) {
        guard isReady else {
            pendingRoutes.append((url, sourceBundleId))
            return
        }

        let stripped = LinkHandlingPreferences.stripTrackingParams
            ? TrackingParamStripper.strip(url)
            : url

        guard LinkHandlingPreferences.unshortenLinks, URLUnshortener.isLikelyShortened(stripped) else {
            routeCleaned(url: stripped, sourceBundleId: sourceBundleId)
            return
        }
        URLUnshortener.resolve(stripped) { [weak self] resolved in
            // Strip again: the real destination behind a shortened link
            // commonly carries its own tracking params that the shortened
            // form never showed.
            let cleaned = LinkHandlingPreferences.stripTrackingParams
                ? TrackingParamStripper.strip(resolved)
                : resolved
            self?.routeCleaned(url: cleaned, sourceBundleId: sourceBundleId)
        }
    }

    private func routeCleaned(url: String, sourceBundleId: String?) {
        openURL(url, in: resolveProfile(url: url, sourceBundleId: sourceBundleId).profile)
    }

    enum Resolution {
        case matchedRule(index: Int)
        case activeWindow
        case fallbackProfile
    }

    /// Where an incoming link belongs, in order:
    /// 1. the profile of the first matching rule (if that profile still exists),
    /// 2. the profile of the frontmost browser window, if one is open,
    /// 3. the configured fallback profile.
    /// The CLI's `open` without `--profile` resolves through this too, so a
    /// CLI open and a clicked link can never land in different places.
    func resolveProfile(url: String, sourceBundleId: String?) -> (profile: Profile, resolution: Resolution) {
        let store = RoutingRulesStore.shared
        let profiles = ProfileManager.shared
        let context = RoutingContext(url: url, sourceBundleId: sourceBundleId)
        let evaluation = RuleMatcher.evaluate(context: context, rules: store.rules, defaultProfileId: store.defaultProfileId)

        if case .matched(let rule, let profileId) = evaluation,
           let profile = profiles.profile(id: profileId),
           let index = store.rules.firstIndex(where: { $0.id == rule.id }) {
            return (profile, .matchedRule(index: index))
        }
        if let controller = WindowManager.shared.frontmostBrowserWindowController {
            return (controller.profile, .activeWindow)
        }
        return (profiles.fallbackProfile, .fallbackProfile)
    }

    /// Opens `url` as a new tab in the frontmost existing window of
    /// `profile`, or a new window for that profile if none is currently
    /// open. Not private: BrowserWindowController's "Move Tab to Profile"
    /// (browser-0y1) reuses this exact path rather than a parallel
    /// implementation, per that task's own note -- a moved tab should land
    /// exactly where a routed link would.
    func openURL(_ url: String, in profile: Profile) {
        if let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            controller.addTab(url: url, makeActive: true)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
