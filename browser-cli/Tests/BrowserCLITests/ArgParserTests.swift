import XCTest
@testable import BrowserCLI

final class ArgParserTests: XCTestCase {
    func testPositionalsOnly() {
        let parsed = ArgParser.parse(["open", "https://example.com"])
        XCTAssertEqual(parsed.positionals, ["open", "https://example.com"])
        XCTAssertTrue(parsed.flags.isEmpty)
        XCTAssertFalse(parsed.jsonOutput)
    }

    func testFlagsInterspersedWithPositionals() {
        let parsed = ArgParser.parse(["open", "https://example.com", "--profile", "work"])
        XCTAssertEqual(parsed.positionals, ["open", "https://example.com"])
        XCTAssertEqual(parsed.flags["profile"], "work")
    }

    func testJSONSwitchDoesNotConsumeAValue() {
        let parsed = ArgParser.parse(["profiles", "--json"])
        XCTAssertTrue(parsed.jsonOutput)
        XCTAssertEqual(parsed.positionals, ["profiles"])
    }

    func testFlagBeforePositional() {
        let parsed = ArgParser.parse(["--profile", "work", "tabs"])
        XCTAssertEqual(parsed.flags["profile"], "work")
        XCTAssertEqual(parsed.positionals, ["tabs"])
    }

    func testTrailingFlagWithNoValueDoesNotCrash() {
        let parsed = ArgParser.parse(["tabs", "--profile"])
        XCTAssertEqual(parsed.flags["profile"], "")
    }

    func testMultipleFlagsAndJSON() {
        let parsed = ArgParser.parse(["history", "search", "github", "--limit", "5", "--profile", "work", "--json"])
        XCTAssertEqual(parsed.positionals, ["history", "search", "github"])
        XCTAssertEqual(parsed.flags["limit"], "5")
        XCTAssertEqual(parsed.flags["profile"], "work")
        XCTAssertTrue(parsed.jsonOutput)
    }
}
