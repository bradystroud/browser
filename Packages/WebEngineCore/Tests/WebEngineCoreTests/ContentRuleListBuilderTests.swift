import XCTest
@testable import WebEngineCore
import BlockListCore

final class ContentRuleListBuilderTests: XCTestCase {
    func testEmptyDomainsProducesEmptyRuleList() {
        XCTAssertEqual(ContentRuleListBuilder.json(blockedDomains: [], allowlistedHosts: []), "[]")
    }

    func testOneRulePerBlockedDomain() throws {
        let json = ContentRuleListBuilder.json(blockedDomains: ["ads.example.com", "tracker.net"], allowlistedHosts: [])
        let rules = try decode(json)
        XCTAssertEqual(rules.count, 2)
    }

    func testEveryRuleBlocks() throws {
        let json = ContentRuleListBuilder.json(blockedDomains: ["ads.example.com"], allowlistedHosts: [])
        let rules = try decode(json)
        for rule in rules {
            let action = rule["action"] as? [String: Any]
            XCTAssertEqual(action?["type"] as? String, "block")
        }
    }

    func testURLFilterMatchesDomainAndSubdomains() throws {
        let json = ContentRuleListBuilder.json(blockedDomains: ["example.com"], allowlistedHosts: [])
        let rules = try decode(json)
        let trigger = rules[0]["trigger"] as? [String: Any]
        let filter = try XCTUnwrap(trigger?["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern: filter, options: .caseInsensitive)

        XCTAssertTrue(matches(regex, "https://example.com/"))
        XCTAssertTrue(matches(regex, "https://ads.example.com/banner.js"))
        XCTAssertTrue(matches(regex, "http://a.b.example.com:8080/x"))
        // Must not false-positive-match a domain that merely ends with the
        // same characters (no dot boundary) -- see BlockList/DomainTrie's
        // own subdomain-inclusive semantics this mirrors.
        XCTAssertFalse(matches(regex, "https://evil-example.com/"))
        XCTAssertFalse(matches(regex, "https://notexample.com/"))
    }

    func testNoUnlessDomainWhenAllowlistEmpty() throws {
        let json = ContentRuleListBuilder.json(blockedDomains: ["example.com"], allowlistedHosts: [])
        let rules = try decode(json)
        let trigger = rules[0]["trigger"] as? [String: Any]
        XCTAssertNil(trigger?["unless-domain"])
    }

    func testAllowlistedHostsBecomeUnlessDomainWithStarPrefix() throws {
        let json = ContentRuleListBuilder.json(blockedDomains: ["ads.example.com"], allowlistedHosts: ["news.example", "Shop.Example"])
        let rules = try decode(json)
        let trigger = rules[0]["trigger"] as? [String: Any]
        let unlessDomain = try XCTUnwrap(trigger?["unless-domain"] as? [String])
        XCTAssertEqual(Set(unlessDomain), ["*news.example", "*shop.example"])
    }

    func testDomainRegexMetacharactersAreEscaped() throws {
        // Not a realistic domain, but proves '.' (the one metacharacter that
        // actually occurs in real hostnames) doesn't act as "any character"
        // -- "exampleXcom" must not match a blocked "example.com" rule.
        let json = ContentRuleListBuilder.json(blockedDomains: ["example.com"], allowlistedHosts: [])
        let rules = try decode(json)
        let trigger = rules[0]["trigger"] as? [String: Any]
        let filter = try XCTUnwrap(trigger?["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern: filter, options: .caseInsensitive)
        XCTAssertFalse(matches(regex, "https://exampleXcom/"))
    }

    func testStarterListProducesOnlyValidFilters() throws {
        let blockList = BlockList()
        blockList.loadStarterList()
        let domains = blockList.allDomains()
        let output = ContentRuleListBuilder.build(blockedDomains: domains, allowlistedHosts: ["news.example"])
        XCTAssertEqual(output.droppedDomains, [])
        XCTAssertEqual(output.ruleCount, domains.count)
        XCTAssertEqual(output.lists.count, 1)
        for rule in try decode(output.lists[0]) {
            let filter = try XCTUnwrap((rule["trigger"] as? [String: Any])?["url-filter"] as? String)
            XCTAssertNil(ContentBlockerRegex.validate(filter), filter)
        }
    }

    func testMouseflowFilterIsValid() throws {
        let filters = try XCTUnwrap(ContentRuleListBuilder.urlFilters(forDomain: "mouseflow.com"))
        XCTAssertEqual(filters, ["^https?://([a-z0-9-]+\\.)*mouseflow\\.com[/:]"])
        XCTAssertNil(ContentBlockerRegex.validate(filters[0]))
    }

    func testDropsDomainsThatCannotBecomeValidFilters() throws {
        let output = ContentRuleListBuilder.build(
            blockedDomains: ["ads.example.com", "bücher.example", "a|b.com", "x{2}.com", "path/evil.com", ""],
            allowlistedHosts: []
        )
        XCTAssertEqual(output.ruleCount, 1)
        XCTAssertEqual(Set(output.droppedDomains), ["bücher.example", "a|b.com", "x{2}.com", "path/evil.com", ""])
        XCTAssertEqual(try decode(output.lists[0]).count, 1)
    }

    func testDropsEverythingIntoEmptyListWhenNothingIsValid() {
        XCTAssertEqual(ContentRuleListBuilder.json(blockedDomains: ["ünïcode.example"], allowlistedHosts: []), "[]")
    }

    func testDeduplicatesCaseInsensitively() throws {
        let output = ContentRuleListBuilder.build(blockedDomains: ["Ads.Example.com", "ads.example.com"], allowlistedHosts: [])
        XCTAssertEqual(output.ruleCount, 1)
    }

    func testSplitsIntoIndependentChunks() throws {
        let domains = (0..<7).map { "tracker\($0).example" }
        let output = ContentRuleListBuilder.build(blockedDomains: domains, allowlistedHosts: [], maxRulesPerList: 3)
        XCTAssertEqual(output.ruleCount, 7)
        XCTAssertEqual(try output.lists.map { try decode($0).count }, [3, 3, 1])
        // Deterministic regardless of input order.
        let reversed = ContentRuleListBuilder.build(blockedDomains: domains.reversed(), allowlistedHosts: [], maxRulesPerList: 3)
        XCTAssertEqual(reversed, output)
    }

    func testChunkSizeNeverExceedsWebKitLimit() {
        let output = ContentRuleListBuilder.build(blockedDomains: ["a.example"], allowlistedHosts: [], maxRulesPerList: 1_000_000)
        XCTAssertEqual(output.lists.count, 1)
    }

    private func decode(_ json: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]])
    }

    private func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
