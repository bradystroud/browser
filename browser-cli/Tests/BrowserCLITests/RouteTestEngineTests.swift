import XCTest
import RoutingCore
@testable import BrowserCLI

final class RouteTestEngineTests: XCTestCase {
    let profiles = [
        ProfileRecord(id: "default-id", name: "default", colorHex: "#007AFF"),
        ProfileRecord(id: "work-id", name: "work", colorHex: "#FF3B30"),
    ]

    func testNoRulesFallsBackToDefaultProfile() throws {
        let configuration = RoutingConfiguration(rules: [], defaultProfileId: "default-id")
        let result = try RouteTestEngine.run(url: "https://example.com", effectiveURL: "https://example.com", fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertNil(result.matchedRuleIndex)
        XCTAssertEqual(result.profileName, "default")
    }

    func testMatchingRuleReportsOneBasedIndexAndSummary() throws {
        let rule = RoutingRule(match: .init(domainGlob: "*.ssw.com.au"), action: .init(profileId: "work-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "default-id")
        let url = "https://rules.ssw.com.au/x"
        let result = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.matchedRuleIndex, 1)
        XCTAssertEqual(result.profileName, "work")
        XCTAssertEqual(result.matchedRuleSummary, "domainGlob=*.ssw.com.au")
    }

    func testFirstMatchWinsOverLaterRules() throws {
        let first = RoutingRule(match: .init(urlContains: "example"), action: .init(profileId: "work-id"))
        let second = RoutingRule(match: .init(urlContains: "example"), action: .init(profileId: "default-id"))
        let configuration = RoutingConfiguration(rules: [first, second], defaultProfileId: "default-id")
        let url = "https://example.com"
        let result = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.matchedRuleIndex, 1)
        XCTAssertEqual(result.profileName, "work")
    }

    func testSourceBundleIdRuleRespectsFromApp() throws {
        let rule = RoutingRule(match: .init(sourceBundleIds: ["com.apple.mail"]), action: .init(profileId: "work-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "default-id")
        let url = "https://example.com"

        let matched = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: "com.apple.mail", configuration: configuration, profiles: profiles)
        XCTAssertEqual(matched.profileName, "work")

        let unmatched = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: "com.apple.Safari", configuration: configuration, profiles: profiles)
        XCTAssertEqual(unmatched.profileName, "default")
        XCTAssertNil(unmatched.matchedRuleIndex)
    }

    func testNoProfilesThrows() {
        let configuration = RoutingConfiguration(rules: [], defaultProfileId: "default-id")
        XCTAssertThrowsError(try RouteTestEngine.run(url: "https://example.com", effectiveURL: "https://example.com", fromApp: nil, configuration: configuration, profiles: []))
    }

    /// The matching itself is always done against `effectiveURL`, not `url`
    /// -- a rule written against a bare domain must still match when the
    /// caller passes a tracking-param-stripped `effectiveURL` that differs
    /// from the original `url` reported back.
    func testMatchingUsesEffectiveURLNotOriginalURL() throws {
        let rule = RoutingRule(match: .init(domainGlob: "ssw.com.au"), action: .init(profileId: "work-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "default-id")
        let decorated = "https://ssw.com.au/?utm_source=newsletter"
        let stripped = "https://ssw.com.au/"

        let result = try RouteTestEngine.run(url: decorated, effectiveURL: stripped, fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.url, decorated)
        XCTAssertEqual(result.effectiveURL, stripped)
        XCTAssertEqual(result.profileName, "work")
        XCTAssertEqual(result.matchedRuleIndex, 1)
    }

    /// Must agree with `RoutingCoordinator`: a matched rule whose profile
    /// was deleted opens in the configured default profile, even when that
    /// profile is not the one named "default".
    func testMatchedRuleWithDeletedProfileFallsBackToConfiguredDefault() throws {
        let rule = RoutingRule(match: .init(domainGlob: "example.com"), action: .init(profileId: "deleted-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "work-id")
        let url = "https://example.com"
        let result = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.matchedRuleIndex, 1)
        XCTAssertEqual(result.profileId, "work-id")
        XCTAssertEqual(result.profileName, "work")
    }

    func testDeletedRuleAndDefaultProfilesFallBackToPersonal() throws {
        let withPersonal = profiles + [ProfileRecord(id: "personal-id", name: "Personal", colorHex: "#34C759")]
        let rule = RoutingRule(match: .init(domainGlob: "example.com"), action: .init(profileId: "deleted-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "also-deleted-id")
        let url = "https://example.com"
        let result = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: nil, configuration: configuration, profiles: withPersonal)
        XCTAssertEqual(result.profileName, "Personal")
    }

    func testDeletedRuleAndDefaultProfilesWithNoPersonalFallBackToFirstProfile() throws {
        let rule = RoutingRule(match: .init(domainGlob: "example.com"), action: .init(profileId: "deleted-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "also-deleted-id")
        let url = "https://example.com"
        let result = try RouteTestEngine.run(url: url, effectiveURL: url, fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.profileId, "default-id")
        XCTAssertEqual(result.profileName, "default")
    }

    func testRoutingConfigurationStoreFallsBackWhenFileMissing() {
        let configuration = RoutingConfigurationStore.load(directory: "/tmp/browser-cli-tests-nonexistent-\(UUID().uuidString)", profiles: profiles)
        XCTAssertTrue(configuration.rules.isEmpty)
        XCTAssertEqual(configuration.defaultProfileId, "default-id")
    }
}
