import AppKit

/// Handoff in both directions.
///
/// Out: the page in the frontmost browser window is published as a
/// `NSUserActivityTypeBrowsingWeb` activity, so a nearby iPhone, iPad or Mac
/// on the same Apple Account can continue it in Safari (or its own default
/// browser). There is no public API to add visits to Safari's iCloud history,
/// so this is how a page gets from this browser to another device.
///
/// In: a web page handed off from another device arrives through
/// `AppDelegate.application(_:continue:restorationHandler:)` and is routed
/// like a clicked link. macOS only hands web pages to the default browser
/// that declares `NSUserActivityTypeBrowsingWeb` in its Info.plist.
///
/// A private window never publishes anything: while one is frontmost, the
/// current activity is withdrawn rather than falling back to a page from
/// another window.
final class HandoffCoordinator: TabLifecycleObserver {
    static let shared = HandoffCoordinator()

    private var activity: NSUserActivity?

    private init() {}

    func start() {
        TabLifecycleCenter.shared.addObserver(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOrderChanged), name: name, object: nil
            )
        }
        update()
    }

    /// Routes a web page handed off from another device. Returns false for
    /// any other activity type, so AppKit can offer it elsewhere.
    func continueActivity(_ userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              Self.isHandoffScheme(url) else { return false }
        RoutingCoordinator.shared.route(url: url.absoluteString, sourceBundleId: nil)
        return true
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        switch event {
        case .becameActive, .navigated, .finishedLoading, .closed:
            update()
        case .opened:
            break
        }
    }

    @objc private func windowOrderChanged(_ notification: Notification) {
        // willClose fires while the closing window is still in
        // NSApp.orderedWindows, so re-read the order on the next turn.
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    private func update() {
        guard let controller = frontmostBrowserWindowController(),
              !controller.isPrivate,
              let tab = controller.activeTab,
              let url = URL(string: tab.urlString),
              Self.isHandoffScheme(url) else {
            withdraw()
            return
        }

        if let activity, activity.webpageURL == url {
            activity.title = tab.title
            return
        }
        withdraw()
        let next = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        next.webpageURL = url
        next.title = tab.title
        next.becomeCurrent()
        activity = next
    }

    private func withdraw() {
        activity?.invalidate()
        activity = nil
    }

    /// Frontmost by z-order, private windows included, so a private window
    /// in front withdraws the activity instead of exposing another window's
    /// page. WindowManager.frontmostBrowserWindowController skips private
    /// windows, which is right for routing links but wrong here.
    private func frontmostBrowserWindowController() -> BrowserWindowController? {
        for window in NSApp.orderedWindows where window.isVisible {
            if let controller = window.windowController as? BrowserWindowController,
               WindowManager.shared.windowControllers.contains(where: { $0 === controller }) {
                return controller
            }
        }
        return nil
    }

    /// NSUserActivity.webpageURL accepts only http and https.
    private static func isHandoffScheme(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }
}
