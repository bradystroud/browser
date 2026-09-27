import Foundation

/// Which way a two-finger swipe navigates. Fingers moving right mean back,
/// as in Safari, whatever the scroll-direction preference.
public enum SwipeDirection: Equatable, Sendable {
    case back
    case forward
}

/// What the edge indicator should show right now.
public struct SwipeIndicatorState: Equatable, Sendable {
    public var direction: SwipeDirection
    /// Finger travel in the swipe's own direction, in points, never negative.
    public var travel: Double
    /// 0 at the first visible point, 1 once armed.
    public var progress: Double
    /// Letting go now navigates.
    public var isArmed: Bool

    public init(direction: SwipeDirection, travel: Double, progress: Double, isArmed: Bool) {
        self.direction = direction
        self.travel = travel
        self.progress = progress
        self.isArmed = isArmed
    }
}

/// The outcome of feeding one event to the tracker.
public struct SwipeEffect: Equatable, Sendable {
    /// nil means no indicator should be on screen.
    public var indicator: SwipeIndicatorState?
    /// The indicator crossed the arm threshold in either direction on this
    /// event, which is the moment for a haptic tick.
    public var armingChanged: Bool
    /// Set only by `end`, when the gesture should navigate.
    public var navigation: SwipeDirection?

    public init(indicator: SwipeIndicatorState? = nil, armingChanged: Bool = false, navigation: SwipeDirection? = nil) {
        self.indicator = indicator
        self.armingChanged = armingChanged
        self.navigation = navigation
    }

    public static let none = SwipeEffect()
}

/// Turns one trackpad scroll gesture into back/forward navigation, for an
/// engine with no native swipe of its own.
///
/// The caller feeds it only live-gesture events (never momentum, never a
/// mouse wheel, which has no phases) and tells it, separately, whether the
/// page said anything under the pointer could scroll sideways. It is
/// deliberately reluctant:
///
/// - the gesture must declare itself clearly horizontal in its first few
///   points, or it is left to the page for good;
/// - nothing is shown until the page has said a sideways scroll would go
///   nowhere, so carousels, maps and wide tables keep every swipe; a page
///   that never answers (not a web page, a crashed renderer) is taken as
///   free after `pageAnswerTimeout`, so it can still be left by hand;
/// - one "taken" answer at any point ends the gesture's claim, the same as
///   Chrome, where a swipe that started out scrolling a carousel never
///   turns into navigation even after the carousel hits its end;
/// - letting go navigates only past `arm`, or on a quick flick past
///   `flick`.
public struct SwipeNavigationTracker: Sendable {
    public struct Thresholds: Equatable, Sendable {
        /// Combined travel on both axes before the gesture's axis is judged.
        public var axisDecisionDistance: Double = 6
        /// How much more horizontal than vertical the start must be.
        public var horizontalDominance: Double = 1.3
        /// Travel before the indicator appears at all.
        public var show: Double = 6
        /// Travel at which letting go navigates.
        public var arm: Double = 70
        /// Shorter travel that still navigates when it happens quickly.
        public var flick: Double = 30
        public var flickWindow: TimeInterval = 0.25
        /// How long to wait for the page's answer before assuming it has none.
        public var pageAnswerTimeout: TimeInterval = 0.18

        public init() {}
    }

    private enum Phase: Equatable, Sendable {
        case idle
        case deciding
        case tracking
        case spent
    }

    private enum PageAnswer: Equatable, Sendable {
        case unknown
        case free
        case taken
    }

    public let thresholds: Thresholds

    private var phase: Phase = .idle
    private var canGoBack = false
    private var canGoForward = false
    private var gatheredX = 0.0
    private var gatheredY = 0.0
    private var sideways = 0.0
    private var direction: SwipeDirection = .back
    private var answer: PageAnswer = .unknown
    private var decidedAt: TimeInterval = 0
    private var armed = false
    /// Identifies the current gesture to the page, which echoes it in every
    /// report, so a late answer about an earlier gesture (a carousel still
    /// gliding from the last swipe) can never speak for this one.
    public private(set) var gesture = 0

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// Whether events for the current gesture are still worth sending. False
    /// once the gesture has been handed to the page or has finished.
    public var isListening: Bool { phase == .deciding || phase == .tracking }

    /// Whether the gesture has committed to being horizontal and navigable.
    public var isTracking: Bool { phase == .tracking }

    /// A new gesture has begun (fingers down).
    public mutating func begin(canGoBack: Bool, canGoForward: Bool) {
        gesture &+= 1
        phase = .deciding
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        gatheredX = 0
        gatheredY = 0
        sideways = 0
        answer = .unknown
        decidedAt = 0
        armed = false
    }

    /// One live-gesture movement. `fingerDeltaX` is positive when the
    /// fingers move right, whatever the scroll-direction preference.
    public mutating func change(fingerDeltaX: Double, deltaY: Double, time: TimeInterval) -> SwipeEffect {
        switch phase {
        case .idle, .spent:
            return .none
        case .deciding:
            gatheredX += abs(fingerDeltaX)
            gatheredY += abs(deltaY)
            sideways += fingerDeltaX
            guard gatheredX + gatheredY > thresholds.axisDecisionDistance else { return .none }
            guard gatheredX > gatheredY * thresholds.horizontalDominance, sideways != 0 else {
                phase = .spent
                return .none
            }
            direction = sideways > 0 ? .back : .forward
            guard direction == .back ? canGoBack : canGoForward else {
                phase = .spent
                return .none
            }
            phase = .tracking
            decidedAt = time
            return evaluate(time: time)
        case .tracking:
            sideways += fingerDeltaX
            return evaluate(time: time)
        }
    }

    /// The page reported whether something under the pointer could scroll
    /// the way the fingers are going, during the gesture it names.
    public mutating func pageAnswered(scrollTaken: Bool, gesture: Int, time: TimeInterval) -> SwipeEffect {
        guard isListening, gesture == self.gesture else { return .none }
        if scrollTaken {
            answer = .taken
            phase = .spent
            return .none
        }
        if answer == .unknown { answer = .free }
        guard phase == .tracking else { return .none }
        return evaluate(time: time)
    }

    /// Fingers lifted.
    public mutating func end(time: TimeInterval) -> SwipeEffect {
        guard phase == .tracking else {
            phase = .idle
            return .none
        }
        let current = evaluate(time: time)
        phase = .idle
        guard answer == .free else { return .none }
        let travel = self.travel
        let flicked = travel >= thresholds.flick && time - decidedAt <= thresholds.flickWindow
        guard armed || flicked else { return SwipeEffect(indicator: nil, armingChanged: false) }
        let state = SwipeIndicatorState(direction: direction, travel: travel, progress: 1, isArmed: true)
        return SwipeEffect(indicator: state, armingChanged: current.armingChanged, navigation: direction)
    }

    /// The system cancelled the gesture.
    public mutating func cancel() -> SwipeEffect {
        phase = .idle
        return .none
    }

    private var travel: Double { max(0, direction == .back ? sideways : -sideways) }

    private mutating func evaluate(time: TimeInterval) -> SwipeEffect {
        if answer == .unknown, time - decidedAt > thresholds.pageAnswerTimeout {
            answer = .free
        }
        guard answer == .free else { return .none }
        let travel = self.travel
        guard travel >= thresholds.show else {
            let changed = armed
            armed = false
            return SwipeEffect(indicator: nil, armingChanged: changed)
        }
        let nowArmed = travel >= thresholds.arm
        let changed = nowArmed != armed
        armed = nowArmed
        let progress = min(1, max(0, (travel - thresholds.show) / (thresholds.arm - thresholds.show)))
        return SwipeEffect(
            indicator: SwipeIndicatorState(direction: direction, travel: travel, progress: progress, isArmed: nowArmed),
            armingChanged: changed)
    }
}

/// Where the swipe indicator sits for a given state. Pure numbers so the
/// feel can be tested and tuned without a trackpad.
public enum SwipeIndicatorGeometry {
    public static let diameter = 52.0

    /// Distance from the page edge to the disc's near edge. Negative while
    /// the disc is still partly off the page: it slides in as the fingers
    /// go, reaches its resting inset when armed, then creeps a little
    /// further with diminishing returns, never following the fingers far.
    public static func edgeInset(for state: SwipeIndicatorState, arm: Double = SwipeNavigationTracker.Thresholds().arm) -> Double {
        let hidden = -diameter * 0.6
        let resting = 14.0
        let overshoot = 24 * (1 - exp(-max(0, state.travel - arm) / 90))
        return hidden + (resting - hidden) * state.progress + overshoot
    }

    public static func scale(for state: SwipeIndicatorState) -> Double {
        0.86 + 0.14 * state.progress
    }
}
