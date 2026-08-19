import XCTest
@testable import UpdateCore

final class AppVersionTests: XCTestCase {
    func testParsesDottedNumericVersions() {
        XCTAssertEqual(AppVersion("0.1.0")?.components, [0, 1, 0])
        XCTAssertEqual(AppVersion("1")?.components, [1])
        XCTAssertEqual(AppVersion("1.2.3.4")?.components, [1, 2, 3, 4])
        XCTAssertEqual(AppVersion("  0.2.0  ")?.components, [0, 2, 0])
    }

    /// Release tags in this repo are "v0.1.0" but CFBundleVersion is "0.1.0",
    /// and the appcast must carry the bare form or Sparkle compares "v0.2.0"
    /// against "0.1.0" and matches nothing.
    func testDropsGitTagPrefix() {
        XCTAssertEqual(AppVersion("v0.1.0")?.components, [0, 1, 0])
        XCTAssertEqual(AppVersion("v0.1.0")?.description, "0.1.0")
        XCTAssertEqual(AppVersion("V2.0")?.description, "2.0")
    }

    func testRejectsNonNumericVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1.0-beta"))
        XCTAssertNil(AppVersion("1..0"))
        XCTAssertNil(AppVersion("1.0."))
        XCTAssertNil(AppVersion("-1.0"))
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion("v"))
    }

    func testOrdersByComponent() {
        XCTAssertLessThan(AppVersion("0.1.0")!, AppVersion("0.2.0")!)
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.1.9")!, AppVersion("0.1.10")!)
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("1.0.1")!)
        XCTAssertGreaterThan(AppVersion("2.0")!, AppVersion("1.99.99")!)
    }

    /// The comparison that a naive string sort gets wrong: "0.10.0" sorts
    /// before "0.9.0" lexically, which would publish an appcast offering
    /// users an older build than the one they have.
    func testStringOrderingWouldBeWrong() {
        XCTAssertTrue("0.10.0" < "0.9.0")
        XCTAssertGreaterThan(AppVersion("0.10.0")!, AppVersion("0.9.0")!)
    }

    func testMissingTrailingComponentsCountAsZero() {
        XCTAssertEqual(AppVersion("1.2")!, AppVersion("1.2.0")!)
        XCTAssertEqual(AppVersion("1")!, AppVersion("1.0.0.0")!)
        XCTAssertLessThan(AppVersion("1.2")!, AppVersion("1.2.1")!)
    }

    func testSortingNewestFirst() {
        let sorted = ["0.1.0", "0.10.0", "0.2.0", "1.0.0", "0.9.0"]
            .compactMap(AppVersion.init)
            .sorted(by: >)
            .map(\.description)
        XCTAssertEqual(sorted, ["1.0.0", "0.10.0", "0.9.0", "0.2.0", "0.1.0"])
    }
}
