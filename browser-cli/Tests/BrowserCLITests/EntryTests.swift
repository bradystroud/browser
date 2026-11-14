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

    func testMalformedProfilesRootIsRejectedRatherThanIgnored() {
        for token in ["--profiles-root /tmp/scratch", "--profiles-root=/tmp/scratch"] {
            XCTAssertThrowsError(try SocketTargetResolver.parse(["profiles", token]))
            XCTAssertFalse(BrowserCLIEntry.run(["profiles", token]))
        }
    }

    func testWellFormedProfilesRootIsAccepted() {
        XCTAssertNoThrow(try SocketTargetResolver.parse(["profiles", "--profiles-root", "/tmp/scratch"]))
        XCTAssertNoThrow(try SocketTargetResolver.parse(["tabs"]))
    }

    func testWindowWithoutNewSubcommandFails() {
        XCTAssertFalse(BrowserCLIEntry.run(["window"]))
        XCTAssertFalse(BrowserCLIEntry.run(["window", "close"]))
    }
}
