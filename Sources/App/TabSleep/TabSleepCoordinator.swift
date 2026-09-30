import Foundation

/// Puts background tabs to sleep: a tab left unselected for
/// TabSleepPreferences.idleInterval (half an hour by default) gives back its
/// engine tab, and with it the page's process memory, timers and sockets.
/// Selecting it again loads the same URL in a fresh engine tab and scrolls
/// back to where it was (Tab.sleep(scrollY:)). Which tabs may sleep is
/// TabSleepPolicy's call; this class gathers what it needs and acts on it.
///
/// A Timer, like TabAudioCoordinator's: idleness is the absence of events,
/// so there is nothing to observe. When macOS reports memory pressure the
/// interval shrinks for one sweep -- to five minutes on a warning, to
/// nothing on a critical one.
final class TabSleepCoordinator: TabLifecycleObserver {
    static let shared = TabSleepCoordinator()

    private var sweepTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    /// Tabs whose page is being asked what it holds, and when the question
    /// went out, so a slow answer isn't asked for again by the next sweep. A
    /// question older than checkTimeout is given up on: a hung page never
    /// answers, and it is exactly the tab that most needs to sleep.
    private let tabsBeingChecked = NSMapTable<Tab, NSDate>.weakToStrongObjects()
    private static let checkTimeout: TimeInterval = 10

    private init() {}

    /// Idempotent -- called from every BrowserWindow's init, the same place
    /// TabAudioCoordinator starts.
    func activate() {
        guard sweepTimer == nil else { return }
        TabLifecycleCenter.shared.addObserver(self)
        NotificationCenter.default.addObserver(
            forName: .tabSleepPreferencesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleSweepTimer()
        }
        scheduleSweepTimer()

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.sweep(pressure: event.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        memoryPressureSource = source
    }

    private func scheduleSweepTimer() {
        sweepTimer?.invalidate()
        let every = TabSleepPolicy.sweepInterval(forIdleInterval: TabSleepPreferences.idleInterval)
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            self?.sweep(pressure: .normal)
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard case .becameActive = event else { return }
        tab.markUsed()
    }

    private func sweep(pressure: TabSleepPolicy.MemoryPressure) {
        guard TabSleepPreferences.isEnabled else { return }
        let idle = TabSleepPolicy.idleInterval(configured: TabSleepPreferences.idleInterval, pressure: pressure)
        let reason: TabMemoryDiagnostics.SleepReason = pressure == .normal ? .idle : .pressure
        for controller in WindowManager.shared.windowControllers {
            // The visible tab is in use for as long as it stays visible, so
            // its clock starts when it stops being the visible one.
            controller.activeTab?.markUsed()
            for tab in controller.tabs {
                sleep(tab, in: controller, trigger: .automatic, idleInterval: idle, reason: reason)
            }
        }
    }

    /// Menu-driven sleep: the idle clock, pinning and an unfinished load are
    /// waived, everything else still applies (see TabSleepPolicy.Trigger).
    func sleepNow(_ tabs: [Tab], in controller: BrowserWindowController) {
        for tab in tabs {
            sleep(tab, in: controller, trigger: .manual, idleInterval: 0, reason: .manual)
        }
    }

    func canSleep(_ tab: Tab, in controller: BrowserWindowController) -> Bool {
        blocker(for: tab, in: controller, trigger: .manual, idleInterval: 0) == nil
    }

    private func blocker(for tab: Tab, in controller: BrowserWindowController, trigger: TabSleepPolicy.Trigger, idleInterval: TimeInterval) -> TabSleepBlocker? {
        // Before the candidate is built: reading devTools or deviceToolbar
        // would create them for a tab that has never had a page.
        guard !tab.isAsleep else { return .alreadyAsleep }
        let candidate = TabSleepCandidate(
            isSelected: tab === controller.activeTab,
            isPrivate: tab.isPrivate,
            isPinned: tab.isPinned,
            isAudible: tab.isAudible,
            isLoading: tab.isLoading,
            hasDevToolsOpen: tab.devTools.isOpen || tab.browser?.isDevToolsOpen == true,
            hasResponsiveDesignMode: tab.deviceToolbar.isOn,
            hasActiveDownload: tab.hasActiveDownload,
            hasLiveOpenedPopup: tab.hasLiveOpenedPopup,
            lastUsed: tab.lastUsed
        )
        return TabSleepPolicy.blocker(for: candidate, trigger: trigger, now: Date(), idleInterval: idleInterval)
    }

    /// The page is asked last, because asking costs a round trip to it; and
    /// the tab is checked again once it answers, since it may have been
    /// selected or started playing in the meantime.
    private func sleep(_ tab: Tab, in controller: BrowserWindowController, trigger: TabSleepPolicy.Trigger, idleInterval: TimeInterval, reason: TabMemoryDiagnostics.SleepReason) {
        if let asked = tabsBeingChecked.object(forKey: tab), -asked.timeIntervalSinceNow < Self.checkTimeout { return }
        guard blocker(for: tab, in: controller, trigger: trigger, idleInterval: idleInterval) == nil else { return }
        let asked = NSDate()
        tabsBeingChecked.setObject(asked, forKey: tab)
        tab.readSleepPageState { [weak self, weak tab, weak controller] page in
            guard let self, let tab, self.tabsBeingChecked.object(forKey: tab) === asked else { return }
            self.tabsBeingChecked.removeObject(forKey: tab)
            guard let controller, controller.tabs.contains(where: { $0 === tab }),
                  self.blocker(for: tab, in: controller, trigger: trigger, idleInterval: idleInterval) == nil,
                  TabSleepPolicy.blocker(for: page) == nil else { return }
            tab.sleep(scrollY: page.scrollY)
            TabMemoryDiagnostics.shared.tabSlept(tab, reason: reason)
        }
    }
}
