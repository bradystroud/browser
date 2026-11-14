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

    func testNewWindowSwitchDoesNotConsumeAValue() {
        let little = ArgParser.parse(["open", "https://example.com", "--little", "--profile", "work"])
        XCTAssertEqual(little.flags["little"], "")
        XCTAssertEqual(little.flags["profile"], "work")

        let parsed = ArgParser.parse(["open", "https://example.com", "--new-window", "--profile", "work"])
        XCTAssertEqual(parsed.positionals, ["open", "https://example.com"])
        XCTAssertNotNil(parsed.flags["new-window"])
        XCTAssertEqual(parsed.flags["new-window"], "")
        XCTAssertEqual(parsed.flags["profile"], "work")
    }

    func testNewWindowSwitchBeforeTheURL() {
        let parsed = ArgParser.parse(["--new-window", "https://example.com"])
        XCTAssertEqual(parsed.positionals, ["https://example.com"])
        XCTAssertNotNil(parsed.flags["new-window"])
    }

    func testAbsentNewWindowSwitchIsNotRecorded() {
        let parsed = ArgParser.parse(["open", "https://example.com"])
        XCTAssertNil(parsed.flags["new-window"])
    }

    func testMultipleFlagsAndJSON() {
        let parsed = ArgParser.parse(["history", "search", "github", "--limit", "5", "--profile", "work", "--json"])
        XCTAssertEqual(parsed.positionals, ["history", "search", "github"])
        XCTAssertEqual(parsed.flags["limit"], "5")
        XCTAssertEqual(parsed.flags["profile"], "work")
        XCTAssertTrue(parsed.jsonOutput)
    }

    /// `--version` is answered before any command word, so it must not take
    /// `--json` (or anything else) as its value.
    func testVersionIsAValuelessFlag() {
        let parsed = ArgParser.parse(["--version", "--json"])
        XCTAssertEqual(parsed.flags["version"], "")
        XCTAssertTrue(parsed.jsonOutput)
        XCTAssertTrue(parsed.positionals.isEmpty)
    }

    /// A switch that took a value would swallow the next flag: once
    /// `--allow-password --selector input` sent `--selector` as the switch's
    /// value and `input` as text to type.
    func testAllowSwitchesKeepTheFollowingFlag() {
        let parsed = ArgParser.parse(["type", "p1", "pw", "--allow-password", "--selector", "input", "--allow-popups", "--json"])
        XCTAssertEqual(parsed.positionals, ["type", "p1", "pw"])
        XCTAssertEqual(parsed.flags["selector"], "input")
        XCTAssertEqual(parsed.flags["allow-password"], "")
        XCTAssertEqual(parsed.flags["allow-popups"], "")
        XCTAssertTrue(parsed.jsonOutput)
    }
}
