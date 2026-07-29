import XCTest
@testable import WebEngineCore

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

    private func decode(_ json: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]])
    }

    private func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
