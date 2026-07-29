import XCTest
@testable import BrowserCore

/// Every fixture here uses synthetic, made-up credentials -- never test
/// this against a real password export (browser-ymx's own scope).
final class PasswordCSVParserTests: XCTestCase {
    func testParsesChromeShapedExport() throws {
        let csv = """
        name,url,username,password,note
        Example Site,https://example.com/login,alice,correct-horse-battery-staple,
        Other Site,https://other.example,bob,hunter2,a note here
        """

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].url, "https://example.com/login")
        XCTAssertEqual(entries[0].username, "alice")
        XCTAssertEqual(entries[0].password, "correct-horse-battery-staple")
        XCTAssertEqual(entries[0].title, "Example Site")
        XCTAssertNil(entries[0].note)
        XCTAssertEqual(entries[1].note, "a note here")
    }

    func testParsesSafariShapedExportWithOTPAuthColumn() throws {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        Example,https://example.com,carol,swordfish123,,otpauth://totp/Example:carol?secret=ABC
        """

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].username, "carol")
        XCTAssertEqual(entries[0].otpAuthURL, "otpauth://totp/Example:carol?secret=ABC")
    }

    func testHeaderColumnMatchingIsCaseInsensitiveAndOrderIndependent() throws {
        let csv = """
        Password,Username,URL
        letmein42,dave,https://example.com
        """

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].username, "dave")
        XCTAssertEqual(entries[0].password, "letmein42")
        XCTAssertEqual(entries[0].url, "https://example.com")
    }

    func testStripsLeadingUTF8BOM() throws {
        let bom = "\u{FEFF}"
        let csv = bom + "url,username,password\nhttps://example.com,erin,pw123\n"

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].username, "erin")
    }

    func testHandlesCRLFLineEndings() throws {
        let csv = "url,username,password\r\nhttps://example.com,frank,pw456\r\n"

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].username, "frank")
    }

    func testQuotedFieldWithEmbeddedCommaAndEscapedQuote() throws {
        let csv = "url,username,password,note\nhttps://example.com,grace,pw789,\"Note, with a comma and a \"\"quoted\"\" word\""

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].note, "Note, with a comma and a \"quoted\" word")
    }

    func testQuotedFieldWithEmbeddedNewline() throws {
        let csv = "url,username,password,note\nhttps://example.com,heidi,pw000,\"line one\nline two\""

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].note, "line one\nline two")
    }

    func testRowsMissingURLOrPasswordAreSkippedRatherThanThrowing() throws {
        let csv = """
        url,username,password
        https://example.com,ivan,pw111
        ,noname,
        https://second.example,judy,pw222
        """

        let entries = try PasswordCSVParser.parse(csv: csv)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.username), ["ivan", "judy"])
    }

    func testEmptyFileThrowsEmptyFile() {
        XCTAssertThrowsError(try PasswordCSVParser.parse(csv: "")) { error in
            XCTAssertEqual(error as? PasswordCSVParser.ParseError, .emptyFile)
        }
    }

    func testUnrecognizedColumnsThrows() {
        let csv = "foo,bar,baz\n1,2,3"
        XCTAssertThrowsError(try PasswordCSVParser.parse(csv: csv)) { error in
            XCTAssertEqual(error as? PasswordCSVParser.ParseError, .unrecognizedColumns)
        }
    }
}

extension PasswordCSVParser.ParseError: Equatable {
    public static func == (lhs: PasswordCSVParser.ParseError, rhs: PasswordCSVParser.ParseError) -> Bool {
        switch (lhs, rhs) {
        case (.emptyFile, .emptyFile), (.unrecognizedColumns, .unrecognizedColumns):
            return true
        default:
            return false
        }
    }
}
