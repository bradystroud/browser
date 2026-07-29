import Foundation
import Testing
@testable import RoutingCore

@Suite("TrackingParamStripper")
struct TrackingParamStripperTests {
    @Test("strips a single known utm_ param via the utm_* prefix entry")
    func stripsUtmPrefix() {
        let result = TrackingParamStripper.strip("https://example.com/page?utm_source=newsletter")
        #expect(result == "https://example.com/page")
    }

    @Test("strips every recognized param while preserving a real one")
    func stripsMultipleKeepsReal() {
        let result = TrackingParamStripper.strip("https://example.com/page?id=42&utm_source=x&utm_campaign=y&fbclid=abc123")
        #expect(result == "https://example.com/page?id=42")
    }

    @Test("exact-name entries (not just the utm_* prefix) are recognized")
    func exactNameEntries() {
        #expect(TrackingParamStripper.strip("https://example.com?gclid=1") == "https://example.com")
        #expect(TrackingParamStripper.strip("https://example.com?msclkid=1") == "https://example.com")
        #expect(TrackingParamStripper.strip("https://example.com?igshid=1") == "https://example.com")
    }

    @Test("param name matching is case-insensitive")
    func caseInsensitiveMatching() {
        let result = TrackingParamStripper.strip("https://example.com?UTM_Source=x&id=1")
        #expect(result == "https://example.com?id=1")
    }

    @Test("a URL with no query string is returned completely unchanged")
    func noQueryStringUnchanged() {
        let url = "https://example.com/page"
        #expect(TrackingParamStripper.strip(url) == url)
    }

    @Test("a URL whose params are all real is returned completely unchanged")
    func allRealParamsUnchanged() {
        let url = "https://example.com/search?q=swift&page=2"
        #expect(TrackingParamStripper.strip(url) == url)
    }

    @Test("the fragment survives stripping")
    func fragmentSurvives() {
        let result = TrackingParamStripper.strip("https://example.com/page?utm_source=x#section-2")
        #expect(result == "https://example.com/page#section-2")
    }

    @Test("stripping every param removes the question mark entirely, not just leaves it empty")
    func removesQuestionMarkWhenEmptied() {
        let result = TrackingParamStripper.strip("https://example.com/page?utm_source=x&fbclid=y")
        #expect(result == "https://example.com/page")
        #expect(!result.contains("?"))
    }

    @Test("an unparseable string is returned unchanged rather than crashing")
    func unparseableStringUnchanged() {
        let notAURL = "not a url at all ??? %"
        #expect(TrackingParamStripper.strip(notAURL) == notAURL)
    }

    @Test("parseList recognizes both exact and prefix entries from arbitrary text")
    func parseListShape() {
        let (exact, prefixes) = TrackingParamStripper.parseList("""
        # a comment, ignored
        exact_one

        prefix_*
        exact_two
        """)
        #expect(exact == ["exact_one", "exact_two"])
        #expect(prefixes == ["prefix_"])
    }
}
