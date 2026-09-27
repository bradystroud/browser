import Foundation

/// Why a tab has to stay awake. `nil` from TabSleepPolicy means nothing does.
enum TabSleepBlocker: String, Equatable {
    /// Already holds no engine tab, so there is nothing to release.
    case alreadyAsleep
    /// The visible tab of its window.
    case selected
    /// Every private tab gets its own throwaway cookie jar on both engines,
    /// created with its engine tab and gone with it. Waking one would sign
    /// it out of everything, so private tabs never sleep.
    case privateBrowsing
    case pinned
    case playingAudio
    case loading
    case devToolsOpen
    case responsiveDesignMode
    /// Download progress is reported through the tab that started it, so
    /// releasing that tab would strand the download's progress in the UI.
    case downloading
    /// A page that opened a popup still open (a sign-in or payment window)
    /// talks back to it through window.opener, which sleep would sever.
    case openedLivePopup
    case pictureInPicture
    case unsavedInput
    /// The page registered a beforeunload handler: its way of saying it has
    /// work not yet saved (an editor with an autosave pending). Sleep closes
    /// the engine tab without running it, so this is the only warning.
    case beforeUnloadGuard
    /// Looked at more recently than the idle interval.
    case recentlyUsed
}

/// A snapshot of everything TabSleepPolicy needs to know about one tab,
/// taken from the app's Tab/BrowserWindowController so the decision itself
/// can be tested without either.
struct TabSleepCandidate: Equatable {
    var isAsleep = false
    var isSelected = false
    var isPrivate = false
    var isPinned = false
    var isAudible = false
    var isLoading = false
    var hasDevToolsOpen = false
    var hasResponsiveDesignMode = false
    var hasActiveDownload = false
    var hasLiveOpenedPopup = false
    var lastUsed = Date.distantPast
}

/// What the page itself reported through TabSleepPageScript's marker
/// attribute, read back just before the tab is released.
struct TabSleepPageState: Equatable {
    var hasUnsavedInput = false
    var isInPictureInPicture = false
    var hasBeforeUnloadHandler = false
    /// Vertical scroll offset in CSS pixels, when the page reported one.
    var scrollY: Int?
}

enum TabSleepPolicy {
    static let defaultIdleInterval: TimeInterval = 30 * 60
    /// Idle interval while macOS reports a memory-pressure warning.
    static let warningIdleInterval: TimeInterval = 5 * 60

    enum MemoryPressure {
        case normal, warning, critical
    }

    /// Who asked. `.manual` is the user choosing a tab from a menu: it waives
    /// the idle clock, pinning and an in-progress load, which are only
    /// guesses about intent the user has just answered. Everything that would
    /// lose something the tab is doing or holding still applies.
    enum Trigger {
        case automatic
        case manual
    }

    /// The first reason `candidate` has to stay awake, or nil. The page's own
    /// state (typed input, picture in picture) is asked separately, in
    /// `blocker(for:)`, because reading it costs an engine round trip.
    static func blocker(
        for candidate: TabSleepCandidate,
        trigger: Trigger,
        now: Date,
        idleInterval: TimeInterval
    ) -> TabSleepBlocker? {
        if candidate.isAsleep { return .alreadyAsleep }
        if candidate.isSelected { return .selected }
        if candidate.isPrivate { return .privateBrowsing }
        if candidate.hasDevToolsOpen { return .devToolsOpen }
        if candidate.hasResponsiveDesignMode { return .responsiveDesignMode }
        if candidate.hasActiveDownload { return .downloading }
        if candidate.isAudible { return .playingAudio }
        if candidate.hasLiveOpenedPopup { return .openedLivePopup }
        guard trigger == .automatic else { return nil }
        if candidate.isPinned { return .pinned }
        if candidate.isLoading { return .loading }
        if now.timeIntervalSince(candidate.lastUsed) < idleInterval { return .recentlyUsed }
        return nil
    }

    static func blocker(for page: TabSleepPageState) -> TabSleepBlocker? {
        if page.isInPictureInPicture { return .pictureInPicture }
        if page.hasUnsavedInput { return .unsavedInput }
        if page.hasBeforeUnloadHandler { return .beforeUnloadGuard }
        return nil
    }

    /// Memory pressure shortens the configured interval, never lengthens it.
    static func idleInterval(configured: TimeInterval, pressure: MemoryPressure) -> TimeInterval {
        switch pressure {
        case .normal: return configured
        case .warning: return min(configured, warningIdleInterval)
        case .critical: return 0
        }
    }

    /// How often to look for idle tabs: a quarter of the interval, between
    /// five seconds and a minute, so a tab sleeps within about a quarter of
    /// its interval of becoming eligible.
    static func sweepInterval(forIdleInterval idle: TimeInterval) -> TimeInterval {
        min(60, max(5, idle / 4))
    }
}
