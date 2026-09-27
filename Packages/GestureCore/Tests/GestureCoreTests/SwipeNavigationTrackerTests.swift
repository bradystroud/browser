import XCTest
@testable import GestureCore

final class SwipeNavigationTrackerTests: XCTestCase {
    private func tracker(canGoBack: Bool = true, canGoForward: Bool = true) -> SwipeNavigationTracker {
        var t = SwipeNavigationTracker()
        t.begin(canGoBack: canGoBack, canGoForward: canGoForward)
        return t
    }

    /// Moves `steps` equal events totalling `dx`, a frame apart from `start`.
    @discardableResult
    private func swipe(_ t: inout SwipeNavigationTracker, dx: Double, dy: Double = 0, steps: Int = 10, start: TimeInterval = 0, frame: TimeInterval = 1.0 / 60) -> SwipeEffect {
        var last = SwipeEffect.none
        for i in 0..<steps {
            last = t.change(fingerDeltaX: dx / Double(steps), deltaY: dy / Double(steps), time: start + Double(i) * frame)
        }
        return last
    }

    func testNothingShowsBeforeThePageAnswers() {
        var t = tracker()
        let effect = swipe(&t, dx: 40, steps: 4)
        XCTAssertTrue(t.isTracking)
        XCTAssertNil(effect.indicator)
    }

    func testFreePageShowsIndicatorAndArmsPastThreshold() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        var effect = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.02)
        XCTAssertEqual(effect.indicator?.direction, .back)
        XCTAssertEqual(effect.indicator?.isArmed, false)
        effect = t.change(fingerDeltaX: 65, deltaY: 0, time: 0.1)
        XCTAssertEqual(effect.indicator?.isArmed, true)
        XCTAssertTrue(effect.armingChanged)
        XCTAssertEqual(effect.indicator?.progress, 1)
        effect = t.change(fingerDeltaX: 5, deltaY: 0, time: 0.12)
        XCTAssertFalse(effect.armingChanged, "arming is reported once, not on every armed event")
    }

    func testArmedReleaseNavigatesBack() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        swipe(&t, dx: 80, steps: 8, start: 0.4)
        let effect = t.end(time: 1)
        XCTAssertEqual(effect.navigation, .back)
        XCTAssertFalse(t.isListening)
    }

    func testFingersLeftGoForward() {
        var t = tracker()
        swipe(&t, dx: -10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        swipe(&t, dx: -90, steps: 9, start: 0.5)
        XCTAssertEqual(t.end(time: 1).navigation, .forward)
    }

    func testReleaseShortOfArmSlowlyDoesNothing() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        swipe(&t, dx: 40, steps: 4, start: 0.5)
        let effect = t.end(time: 1)
        XCTAssertNil(effect.navigation)
        XCTAssertNil(effect.indicator)
    }

    func testQuickFlickPastFlickThresholdNavigates() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2, frame: 0.01)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.02)
        _ = t.change(fingerDeltaX: 30, deltaY: 0, time: 0.05)
        XCTAssertEqual(t.end(time: 0.1).navigation, .back)
    }

    func testDrawnBackBelowArmCancels() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        _ = t.change(fingerDeltaX: 80, deltaY: 0, time: 0.4)
        let back = t.change(fingerDeltaX: -60, deltaY: 0, time: 0.6)
        XCTAssertEqual(back.indicator?.isArmed, false)
        XCTAssertTrue(back.armingChanged)
        XCTAssertNil(t.end(time: 1).navigation)
    }

    func testDrawnPastOriginHidesIndicator() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        _ = t.change(fingerDeltaX: 20, deltaY: 0, time: 0.1)
        XCTAssertNil(t.change(fingerDeltaX: -60, deltaY: 0, time: 0.2).indicator)
    }

    func testVerticalGestureIsLeftToThePage() {
        var t = tracker()
        swipe(&t, dx: 5, dy: 20, steps: 4)
        XCTAssertFalse(t.isListening)
        XCTAssertEqual(t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.1), .none)
        XCTAssertNil(t.end(time: 1).navigation)
    }

    func testDiagonalWithoutClearHorizontalDominanceIsLeftToThePage() {
        var t = tracker()
        swipe(&t, dx: 12, dy: 10, steps: 4)
        XCTAssertFalse(t.isListening)
    }

    func testAxisIsNotJudgedWithinTheFirstFewPoints() {
        var t = tracker()
        _ = t.change(fingerDeltaX: 1, deltaY: 4, time: 0)
        XCTAssertTrue(t.isListening)
        XCTAssertFalse(t.isTracking)
    }

    func testNoHistoryThatWayMeansNoClaim() {
        var t = tracker(canGoBack: false)
        swipe(&t, dx: 30, steps: 3)
        XCTAssertFalse(t.isListening)
        var f = tracker(canGoForward: false)
        swipe(&f, dx: -30, steps: 3)
        XCTAssertFalse(f.isListening)
    }

    func testTakenAnswerEndsTheClaimForTheWholeGesture() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        XCTAssertEqual(t.pageAnswered(scrollTaken: true, gesture: t.gesture, time: 0.01), .none)
        XCTAssertFalse(t.isListening)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.05)
        XCTAssertNil(t.change(fingerDeltaX: 100, deltaY: 0, time: 0.1).indicator)
        XCTAssertNil(t.end(time: 1).navigation)
    }

    func testTakenAfterIndicatorShowingWithdrawsIt() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        XCTAssertNotNil(t.change(fingerDeltaX: 30, deltaY: 0, time: 0.1).indicator)
        XCTAssertNil(t.pageAnswered(scrollTaken: true, gesture: t.gesture, time: 0.12).indicator)
        XCTAssertNil(t.end(time: 1).navigation)
    }

    func testAnswerBeforeAxisDecisionIsKept() {
        var t = tracker()
        _ = t.change(fingerDeltaX: 2, deltaY: 0, time: 0)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.005)
        let effect = t.change(fingerDeltaX: 10, deltaY: 0, time: 0.02)
        XCTAssertNotNil(effect.indicator)
    }

    func testSilentPageIsTakenAsFreeAfterTimeout() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        XCTAssertNil(t.change(fingerDeltaX: 10, deltaY: 0, time: 0.1).indicator)
        XCTAssertNotNil(t.change(fingerDeltaX: 10, deltaY: 0, time: 0.3).indicator)
    }

    func testFlickBeforeAnyAnswerDoesNotNavigate() {
        var t = tracker()
        swipe(&t, dx: 50, steps: 3, frame: 0.01)
        XCTAssertNil(t.end(time: 0.05).navigation)
    }

    func testCancelledGestureNeverNavigates() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 0.01)
        _ = t.change(fingerDeltaX: 100, deltaY: 0, time: 0.3)
        XCTAssertEqual(t.cancel(), .none)
        XCTAssertNil(t.end(time: 0.5).navigation)
    }

    func testEventsBeforeBeginAreIgnored() {
        var t = SwipeNavigationTracker()
        XCTAssertEqual(t.change(fingerDeltaX: 100, deltaY: 0, time: 0), .none)
        XCTAssertNil(t.end(time: 1).navigation)
    }

    func testLateAnswerFromAnEarlierGestureIsIgnored() {
        var t = tracker()
        let first = t.gesture
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: true, gesture: first, time: 0.01)
        _ = t.end(time: 0.2)
        t.begin(canGoBack: true, canGoForward: true)
        XCTAssertNotEqual(t.gesture, first)
        swipe(&t, dx: 10, steps: 2, start: 0.3)
        XCTAssertEqual(t.pageAnswered(scrollTaken: false, gesture: first, time: 0.32), .none)
        XCTAssertNil(t.change(fingerDeltaX: 20, deltaY: 0, time: 0.35).indicator,
                     "a stale free answer must not free the new gesture")
        _ = t.pageAnswered(scrollTaken: true, gesture: t.gesture, time: 0.36)
        XCTAssertNil(t.change(fingerDeltaX: 100, deltaY: 0, time: 0.6).indicator)
        XCTAssertNil(t.end(time: 0.7).navigation)
    }

    func testCarouselAnsweringEveryGestureNeverNavigates() {
        var t = tracker()
        for round in 0..<5 {
            let start = Double(round) * 0.4
            t.begin(canGoBack: true, canGoForward: true)
            swipe(&t, dx: 10, steps: 2, start: start)
            _ = t.pageAnswered(scrollTaken: true, gesture: t.gesture, time: start + 0.02)
            swipe(&t, dx: 100, steps: 5, start: start + 0.05)
            XCTAssertNil(t.end(time: start + 0.3).navigation)
        }
    }

    func testNewGestureStartsClean() {
        var t = tracker()
        swipe(&t, dx: 10, steps: 2)
        _ = t.pageAnswered(scrollTaken: true, gesture: t.gesture, time: 0.01)
        t.begin(canGoBack: true, canGoForward: true)
        XCTAssertTrue(t.isListening)
        swipe(&t, dx: 10, steps: 2, start: 2)
        _ = t.pageAnswered(scrollTaken: false, gesture: t.gesture, time: 2.05)
        swipe(&t, dx: 80, steps: 4, start: 2.4)
        XCTAssertEqual(t.end(time: 3).navigation, .back)
    }
}

final class SwipeIndicatorGeometryTests: XCTestCase {
    private func state(_ travel: Double) -> SwipeIndicatorState {
        let t = SwipeNavigationTracker.Thresholds()
        let progress = min(1, max(0, (travel - t.show) / (t.arm - t.show)))
        return SwipeIndicatorState(direction: .back, travel: travel, progress: progress, isArmed: travel >= t.arm)
    }

    func testStartsPartlyOffThePage() {
        XCTAssertLessThan(SwipeIndicatorGeometry.edgeInset(for: state(6)), 0)
        XCTAssertGreaterThan(SwipeIndicatorGeometry.edgeInset(for: state(6)), -SwipeIndicatorGeometry.diameter)
    }

    func testFullyOnThePageOnceArmed() {
        XCTAssertGreaterThan(SwipeIndicatorGeometry.edgeInset(for: state(70)), 0)
    }

    func testMovesMonotonicallyAndStaysNearTheEdge() {
        var previous = -Double.infinity
        for travel in stride(from: 6.0, through: 2000, by: 5) {
            let inset = SwipeIndicatorGeometry.edgeInset(for: state(travel))
            XCTAssertGreaterThanOrEqual(inset, previous)
            XCTAssertLessThan(inset, 40, "the disc must never chase the fingers across the page")
            previous = inset
        }
    }

    func testScaleGrowsToFullSize() {
        XCTAssertEqual(SwipeIndicatorGeometry.scale(for: state(6)), 0.86, accuracy: 0.0001)
        XCTAssertEqual(SwipeIndicatorGeometry.scale(for: state(500)), 1, accuracy: 0.0001)
    }
}
