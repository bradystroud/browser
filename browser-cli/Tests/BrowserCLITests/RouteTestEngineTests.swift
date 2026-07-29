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
        let result = try RouteTestEngine.run(url: "https://example.com", fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertNil(result.matchedRuleIndex)
        XCTAssertEqual(result.profileName, "default")
    }

    func testMatchingRuleReportsOneBasedIndexAndSummary() throws {
        let rule = RoutingRule(match: .init(domainGlob: "*.ssw.com.au"), action: .init(profileId: "work-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "default-id")
        let result = try RouteTestEngine.run(url: "https://rules.ssw.com.au/x", fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.matchedRuleIndex, 1)
        XCTAssertEqual(result.profileName, "work")
        XCTAssertEqual(result.matchedRuleSummary, "domainGlob=*.ssw.com.au")
    }

    func testFirstMatchWinsOverLaterRules() throws {
        let first = RoutingRule(match: .init(urlContains: "example"), action: .init(profileId: "work-id"))
        let second = RoutingRule(match: .init(urlContains: "example"), action: .init(profileId: "default-id"))
        let configuration = RoutingConfiguration(rules: [first, second], defaultProfileId: "default-id")
        let result = try RouteTestEngine.run(url: "https://example.com", fromApp: nil, configuration: configuration, profiles: profiles)
        XCTAssertEqual(result.matchedRuleIndex, 1)
        XCTAssertEqual(result.profileName, "work")
    }

    func testSourceBundleIdRuleRespectsFromApp() throws {
        let rule = RoutingRule(match: .init(sourceBundleIds: ["com.apple.mail"]), action: .init(profileId: "work-id"))
        let configuration = RoutingConfiguration(rules: [rule], defaultProfileId: "default-id")

        let matched = try RouteTestEngine.run(url: "https://example.com", fromApp: "com.apple.mail", configuration: configuration, profiles: profiles)
        XCTAssertEqual(matched.profileName, "work")

        let unmatched = try RouteTestEngine.run(url: "https://example.com", fromApp: "com.apple.Safari", configuration: configuration, profiles: profiles)
        XCTAssertEqual(unmatched.profileName, "default")
        XCTAssertNil(unmatched.matchedRuleIndex)
    }

    func testNoProfilesThrows() {
        let configuration = RoutingConfiguration(rules: [], defaultProfileId: "default-id")
        XCTAssertThrowsError(try RouteTestEngine.run(url: "https://example.com", fromApp: nil, configuration: configuration, profiles: []))
    }

    func testRoutingConfigurationStoreFallsBackWhenFileMissing() {
        let configuration = RoutingConfigurationStore.load(directory: "/tmp/browser-cli-tests-nonexistent-\(UUID().uuidString)", profiles: profiles)
        XCTAssertTrue(configuration.rules.isEmpty)
        XCTAssertEqual(configuration.defaultProfileId, "default-id")
    }
}
