import Foundation
import Testing
@testable import RoutingCore

@Suite("Rule action openIn persistence")
struct OpenInCodingTests {
    @Test("routing.json written before openIn existed still decodes, with openIn nil")
    func legacyFileDecodes() throws {
        let json = """
        {"defaultProfileId":"p-default","rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF",
        "match":{"domainGlob":"*.example.com"},"action":{"profileId":"p-work"}}]}
        """
        let configuration = try JSONDecoder().decode(RoutingConfiguration.self, from: Data(json.utf8))
        #expect(configuration.rules.count == 1)
        #expect(configuration.rules[0].action.profileId == "p-work")
        #expect(configuration.rules[0].action.openIn == nil)
    }

    @Test("a nil openIn is omitted when encoding, so older builds see an unchanged action")
    func nilOpenInOmitted() throws {
        let data = try JSONEncoder().encode(RoutingRule.Action(profileId: "p"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["openIn"] == nil)
        #expect(object?["profileId"] as? String == "p")
    }

    @Test("openIn round-trips")
    func roundTrip() throws {
        for openIn in RoutingRule.OpenIn.allCases {
            let action = RoutingRule.Action(profileId: "p", openIn: openIn)
            let decoded = try JSONDecoder().decode(RoutingRule.Action.self, from: JSONEncoder().encode(action))
            #expect(decoded == action)
        }
        let data = try JSONEncoder().encode(RoutingRule.Action(profileId: "p", openIn: .littleWindow))
        #expect(String(decoding: data, as: UTF8.self).contains("\"littleWindow\""))
    }

    @Test("an openIn value from a newer build decodes as nil instead of failing the file")
    func unknownValueTolerated() throws {
        let json = #"{"profileId":"p","openIn":"somethingNew"}"#
        let action = try JSONDecoder().decode(RoutingRule.Action.self, from: Data(json.utf8))
        #expect(action.profileId == "p")
        #expect(action.openIn == nil)
    }
}

@Suite("Little window resolution")
struct LinkOpeningResolveTests {
    private func rule(_ openIn: RoutingRule.OpenIn?) -> RoutingRule {
        RoutingRule(match: .init(domainGlob: "example.com"), action: .init(profileId: "p", openIn: openIn))
    }

    private func evaluate(_ rules: [RoutingRule], url: String = "https://example.com/") -> RuleEvaluation {
        RuleMatcher.evaluate(context: RoutingContext(url: url, sourceBundleId: nil), rules: rules, defaultProfileId: "d")
    }

    @Test("with no rule and the preference off, links open in the browser")
    func defaultIsBrowser() {
        let opening = LinkOpening.resolve(evaluation: evaluate([]), preferLittleWindowForExternalLinks: false)
        #expect(opening == LinkOpening(openIn: .browser, reason: .default))
    }

    @Test("with no rule and the preference on, links open in a little window")
    func preferenceOn() {
        let opening = LinkOpening.resolve(evaluation: evaluate([]), preferLittleWindowForExternalLinks: true)
        #expect(opening == LinkOpening(openIn: .littleWindow, reason: .preference))
    }

    @Test("a matched rule with no openIn defers to the preference")
    func silentRuleDefers() {
        let evaluation = evaluate([rule(nil)])
        #expect(evaluation.openIn == nil)
        #expect(LinkOpening.resolve(evaluation: evaluation, preferLittleWindowForExternalLinks: true).reason == .preference)
        #expect(LinkOpening.resolve(evaluation: evaluation, preferLittleWindowForExternalLinks: false).openIn == .browser)
    }

    @Test("a rule's openIn overrides the preference in both directions")
    func ruleOverrides() {
        let little = LinkOpening.resolve(evaluation: evaluate([rule(.littleWindow)]), preferLittleWindowForExternalLinks: false)
        #expect(little == LinkOpening(openIn: .littleWindow, reason: .rule))
        let browser = LinkOpening.resolve(evaluation: evaluate([rule(.browser)]), preferLittleWindowForExternalLinks: true)
        #expect(browser == LinkOpening(openIn: .browser, reason: .rule))
    }

    @Test("a non-matching rule's openIn is ignored")
    func nonMatchingRuleIgnored() {
        let evaluation = evaluate([rule(.littleWindow)], url: "https://other.org/")
        #expect(evaluation.openIn == nil)
        #expect(LinkOpening.resolve(evaluation: evaluation, preferLittleWindowForExternalLinks: false).openIn == .browser)
    }
}
