import XCTest
@testable import BrowserCLI

final class EntryTests: XCTestCase {
    func testNoArgumentsFails() {
        XCTAssertFalse(BrowserCLIEntry.run([]))
    }

    func testUnknownCommandFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["frobnicate"]))
    }

    func testHelpSucceeds() {
        XCTAssertTrue(BrowserCLIEntry.run(["help"]))
    }

    func testHistoryWithoutSearchSubcommandFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["history"]))
        XCTAssertFalse(BrowserCLIEntry.run(["history", "delete"]))
    }

    func testBookmarksWithoutListSubcommandFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["bookmarks"]))
        XCTAssertFalse(BrowserCLIEntry.run(["bookmarks", "add"]))
    }

    func testOpenWithoutURLFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["open"]))
    }

    func testRouteTestWithoutURLFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["route-test"]))
    }

    /// The failure mode this guard exists for retargets a "scratch" command
    /// at the real running browser -- see
    /// BrowserCLIEntry.malformedProfilesRootArgument.
    func testMalformedProfilesRootIsRejectedRatherThanIgnored() {
        XCTAssertEqual(
            BrowserCLIEntry.malformedProfilesRootArgument(in: ["profiles", "--profiles-root /tmp/scratch"]),
            "--profiles-root /tmp/scratch"
        )
        XCTAssertEqual(
            BrowserCLIEntry.malformedProfilesRootArgument(in: ["profiles", "--profiles-root=/tmp/scratch"]),
            "--profiles-root=/tmp/scratch"
        )
        XCTAssertFalse(BrowserCLIEntry.run(["profiles", "--profiles-root /tmp/scratch"]))
    }

    func testWellFormedProfilesRootIsAccepted() {
        XCTAssertNil(BrowserCLIEntry.malformedProfilesRootArgument(in: ["profiles", "--profiles-root", "/tmp/scratch"]))
        XCTAssertNil(BrowserCLIEntry.malformedProfilesRootArgument(in: ["tabs"]))
    }

    func testWindowWithoutNewSubcommandFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["window"]))
        XCTAssertFalse(BrowserCLIEntry.run(["window", "close"]))
    }
}
