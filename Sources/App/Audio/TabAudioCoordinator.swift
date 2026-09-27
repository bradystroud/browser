import Foundation

/// App-wide singleton that keeps every open tab's Tab.isAudible in sync with
/// whatever AudioStateScript's marker attribute currently says (browser-
/// rhi.4). Polls every tab in every window -- not just each window's active
/// tab -- since the whole point of a per-tab audio indicator is finding
/// *which* background tab is making noise; only ever looking at the active
/// tab (as ReaderModeController does for its own single floating button)
/// would defeat that purpose here.
///
/// Deliberately still a Timer after browser-g6d moved every other per-
/// feature poller in this app onto TabLifecycleCenter: this one was never
/// doing tab *discovery* or "is this still the active tab" reconciliation
/// (the two things lifecycle events replace). It re-reads a page state that
/// has no native event of any kind behind it -- audio can start or stop at
/// any moment, with no navigation, focus change or CEF callback to hang off
/// -- so periodic sampling is the mechanism, not a workaround for a missing
/// signal. Left exactly as it was.
///
/// Uses tab.getPageSource(completion:) + a marker-attribute substring check
/// (AudioStateScript.isMarkedAudible(inSource:)), the same pattern
/// ReaderModeController/ReaderTemplate already established, rather than the
/// cefQuery page-message channel PasswordManagerCoordinator uses -- see
/// AudioStateScript's own doc comment for why (that channel has exactly one
/// consumer slot per tab, already claimed).
///
/// Deliberate cost trade-off, flagged honestly rather than silently
/// accepted: CefFrame::GetSource reads the *entire* page's HTML on every
/// poll tick, for every open tab, not just a cheap flag read -- there's no
/// cheaper CEF-native partial-read primitive available (confirmed by every
/// other feature built on GetSource in this codebase -- Reader mode's
/// readerable check, browser-rhi.5's theme-color extraction -- hitting the
/// same limitation). The poll interval here (1.5s) was deliberately coarser
/// than the 400-500ms pollers this app used to have elsewhere, to keep that
/// cost down -- a ~1.5s lag before a speaker icon appears/disappears is an
/// acceptable trade for a background indicator, unlike Reader mode's
/// user-facing toggle button. This is now the only Timer of its kind left.
final class TabAudioCoordinator {
    static let shared = TabAudioCoordinator()

    private var pollTimer: Timer?
    /// Tabs with an audible-state check currently in flight -- skipped on
    /// the next tick rather than queued, so a slow/stalled getPageSource
    /// response can't pile up repeated requests for the same tab.
    private var tabsWithRequestInFlight = NSHashTable<Tab>.weakObjects()

    private init() {}

    /// Idempotent -- called from BrowserWindow.swift's init, same pattern as
    /// PasswordManagerCoordinator.activate()/ReaderModeController.attach(to:)
    /// (see those own doc comments for why new per-feature wiring lives
    /// there rather than in BrowserWindowController/AppDelegate).
    func activate() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs {
                checkAudibleState(for: tab)
            }
        }
    }

    private func checkAudibleState(for tab: Tab) {
        // A loading/about:blank/start-page tab has no real document worth
        // reading yet -- skip rather than waste a GetSource round-trip on
        // something that's about to change anyway.
        guard !tab.isAsleep, !tab.isLoading, !tab.isShowingStartPage else { return }
        guard !tabsWithRequestInFlight.contains(tab) else { return }
        tabsWithRequestInFlight.add(tab)
        tab.getPageSource { [weak self, weak tab] source in
            guard let self, let tab else { return }
            self.tabsWithRequestInFlight.remove(tab)
            let audible = source.map(AudioStateScript.isMarkedAudible(inSource:)) ?? false
            tab.updateAudibleState(audible)
        }
    }
}
