import XCTest
@testable import WebEngineCore

final class ContentBlockerRegexTests: XCTestCase {
    func testAcceptsSupportedSubset() {
        for pattern in [
            "^https?://([a-z0-9-]+\\.)*mouseflow\\.com[/:]",
            "ads",
            "^https://example\\.com/$",
            "[^a-z]+x?",
            "a.*b",
            "[]a]",
            "\\|literal-pipe\\{",
            "((ab)+c)*",
        ] {
            XCTAssertNil(ContentBlockerRegex.validate(pattern), pattern)
        }
    }

    func testRejectsTheFilterWebKitReportedAsDisjunction() {
        // The template every rule used to carry -- WebKit error 6,
        // "Disjunctions are not supported yet".
        XCTAssertEqual(
            ContentBlockerRegex.validate("^https?://([a-z0-9-]+\\.)*mouseflow\\.com([/:]|$)"),
            .disjunction
        )
    }

    func testRejectsUnsupportedSyntax() {
        let cases: [(String, ContentBlockerRegex.ValidationError)] = [
            ("a|b", .disjunction),
            ("a{2}", .countedQuantifier),
            ("a{1,3}", .countedQuantifier),
            ("(a)\\1", .backreference),
            ("\\d+", .builtinCharacterClass),
            ("[\\w]", .builtinCharacterClass),
            ("\\bads", .builtinCharacterClass),
            ("(?=a)b", .unsupportedGroup),
            ("(?!a)b", .unsupportedGroup),
            ("(?<=a)b", .unsupportedGroup),
            ("(?:a)b", .unsupportedGroup),
            ("exämple", .nonASCII),
            ("a^b", .misplacedStartAnchor),
            ("a$b", .misplacedEndAnchor),
            ("*a", .quantifierWithoutAtom),
            ("a*?", .quantifierWithoutAtom),
            ("a++", .quantifierWithoutAtom),
            ("(a", .unbalancedParentheses),
            ("a)", .unbalancedParentheses),
            ("a()", .emptyGroup),
            ("[abc", .unterminatedCharacterClass),
            ("abc\\", .trailingBackslash),
            ("", .empty),
        ]
        for (pattern, expected) in cases {
            XCTAssertEqual(ContentBlockerRegex.validate(pattern), expected, pattern)
        }
    }

    func testExpandsFiniteDisjunctions() throws {
        let expanded = try XCTUnwrap(ContentBlockerRegex.expandDisjunctions("^https?://ads\\.(foo|bar)\\.com[/:]"))
        XCTAssertEqual(expanded, ["^https?://ads\\.(foo)\\.com[/:]", "^https?://ads\\.(bar)\\.com[/:]"])
        for pattern in expanded { XCTAssertNil(ContentBlockerRegex.validate(pattern)) }
    }

    func testExpandsTopLevelAndNestedDisjunctions() throws {
        XCTAssertEqual(ContentBlockerRegex.expandDisjunctions("a|b"), ["a", "b"])
        let nested = try XCTUnwrap(ContentBlockerRegex.expandDisjunctions("x(a(b|c)|d)y"))
        XCTAssertEqual(Set(nested), ["x(a(b))y", "x(a(c))y", "x(d)y"])
    }

    func testLeavesDisjunctionFreePatternsAlone() {
        XCTAssertEqual(ContentBlockerRegex.expandDisjunctions("a(b)+[|]\\|c"), ["a(b)+[|]\\|c"])
    }

    func testRefusesQuantifiedDisjunctions() {
        XCTAssertNil(ContentBlockerRegex.expandDisjunctions("(a|b)*"))
        XCTAssertNil(ContentBlockerRegex.expandDisjunctions("(a|b)+c"))
    }

    func testRefusesExpansionsOverTheLimit() {
        // 2^4 = 16 alternatives.
        XCTAssertNil(ContentBlockerRegex.expandDisjunctions("(a|b)(c|d)(e|f)(g|h)", limit: 8))
        XCTAssertEqual(ContentBlockerRegex.expandDisjunctions("(a|b)(c|d)(e|f)(g|h)", limit: 16)?.count, 16)
    }
}
