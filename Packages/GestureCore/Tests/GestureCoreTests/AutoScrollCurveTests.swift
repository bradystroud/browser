import JavaScriptCore
import XCTest
@testable import GestureCore

final class AutoScrollCurveTests: XCTestCase {
    func testDeadZoneHoldsStill() {
        for offset in stride(from: -12.0, through: 12, by: 0.5) {
            XCTAssertEqual(AutoScrollCurve.speed(offset: offset), 0)
        }
    }

    func testSpeedIsSignedBySide() {
        XCTAssertGreaterThan(AutoScrollCurve.speed(offset: 50), 0)
        XCTAssertLessThan(AutoScrollCurve.speed(offset: -50), 0)
        XCTAssertEqual(AutoScrollCurve.speed(offset: 50), -AutoScrollCurve.speed(offset: -50))
    }

    func testSpeedGrowsWithDistanceAndIsCapped() {
        var previous = 0.0
        for offset in stride(from: 13.0, through: 3000, by: 7) {
            let speed = AutoScrollCurve.speed(offset: offset)
            XCTAssertGreaterThanOrEqual(speed, previous)
            XCTAssertLessThanOrEqual(speed, AutoScrollCurve.maxSpeed)
            previous = speed
        }
        XCTAssertEqual(AutoScrollCurve.speed(offset: 5000), AutoScrollCurve.maxSpeed)
    }

    func testCurveIsGentleNearTheMark() {
        // A little past the dead zone is a slow crawl a reader can follow,
        // not a lurch.
        XCTAssertLessThan(AutoScrollCurve.speed(offset: 22), 100)
        XCTAssertGreaterThan(AutoScrollCurve.speed(offset: 150), 1000)
    }

    func testJavaScriptTwinMatchesSwift() throws {
        let context = try XCTUnwrap(JSContext())
        let speed = try XCTUnwrap(context.evaluateScript("(\(AutoScrollCurve.javaScriptFunction))"))
        XCTAssertNil(context.exception)
        for offset in [-4000.0, -300, -40, -12.5, -3, 0, 3, 12.5, 13, 40, 300, 4000] {
            let js = try XCTUnwrap(speed.call(withArguments: [offset])).toDouble()
            XCTAssertEqual(js, AutoScrollCurve.speed(offset: offset), accuracy: 0.0001, "offset \(offset)")
        }
    }
}
