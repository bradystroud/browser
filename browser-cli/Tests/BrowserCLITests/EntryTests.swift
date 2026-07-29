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
}
