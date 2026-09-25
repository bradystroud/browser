import Foundation
import Testing
@testable import RoutingCore

@Suite("Domain glob matching")
struct DomainGlobTests {
    @Test("bare domain matches only the exact host")
    func bareDomainExactMatch() {
        #expect(RuleMatcher.matchesDomainGlob("example.com", host: "example.com"))
        #expect(!RuleMatcher.matchesDomainGlob("example.com", host: "www.example.com"))
        #expect(!RuleMatcher.matchesDomainGlob("example.com", host: "notexample.com"))
        #expect(!RuleMatcher.matchesDomainGlob("example.com", host: "example.com.evil.com"))
    }

    @Test("wildcard domain matches the bare host and any subdomain")
    func wildcardSubdomainInclusive() {
        #expect(RuleMatcher.matchesDomainGlob("*.example.com", host: "example.com"))
        #expect(RuleMatcher.matchesDomainGlob("*.example.com", host: "www.example.com"))
        #expect(RuleMatcher.matchesDomainGlob("*.example.com", host: "a.b.example.com"))
        #expect(!RuleMatcher.matchesDomainGlob("*.example.com", host: "notexample.com"))
        #expect(!RuleMatcher.matchesDomainGlob("*.example.com", host: "example.com.evil.com"))
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(RuleMatcher.matchesDomainGlob("Example.COM", host: "example.com"))
        #expect(RuleMatcher.matchesDomainGlob("*.Example.com", host: "WWW.example.COM"))
    }

    @Test("an internationalized glob matches the punycode host a URL parses to")
    func internationalizedDomain() {
        let rule = RoutingRule.Match(domainGlob: "bücher.de")
        #expect(RuleMatcher.matches(rule, context: RoutingContext(url: "https://bücher.de/x", sourceBundleId: nil)))
        #expect(RuleMatcher.matches(rule, context: RoutingContext(url: "https://xn--bcher-kva.de/x", sourceBundleId: nil)))
        #expect(RuleMatcher.matchesDomainGlob("xn--bcher-kva.de", host: "bücher.de"))
        #expect(!RuleMatcher.matchesDomainGlob("bucher.de", host: "xn--bcher-kva.de"))
    }

    @Test("a single trailing dot on either side is ignored")
    func trailingDot() {
        #expect(RuleMatcher.matchesDomainGlob("example.com", host: "example.com."))
        #expect(RuleMatcher.matchesDomainGlob("example.com.", host: "example.com"))
        let rule = RoutingRule.Match(domainGlob: "example.com")
        #expect(RuleMatcher.matches(rule, context: RoutingContext(url: "https://example.com./path", sourceBundleId: nil)))
    }

    @Test("the *. wildcard composes with internationalized names and trailing dots")
    func wildcardWithIdnAndTrailingDot() {
        #expect(RuleMatcher.matchesDomainGlob("*.bücher.de", host: "xn--bcher-kva.de"))
        #expect(RuleMatcher.matchesDomainGlob("*.bücher.de", host: "shop.xn--bcher-kva.de."))
        #expect(RuleMatcher.matchesDomainGlob("*.BÜCHER.de", host: "shop.bücher.de"))
        #expect(RuleMatcher.matchesDomainGlob("*.example.com.", host: "www.example.com."))
        #expect(!RuleMatcher.matchesDomainGlob("*.bücher.de", host: "xn--bcher-kva.de.evil.com"))
    }

    @Test("host extraction from a URL string")
    func hostExtraction() {
        #expect(RuleMatcher.host(of: "https://sub.example.com/path?q=1") == "sub.example.com")
        #expect(RuleMatcher.host(of: "not a url") == nil)
    }
}

@Suite("URL contains matching")
struct UrlContainsTests {
    @Test("matches a substring anywhere in the URL")
    func substringAnywhere() {
        let match = RoutingRule.Match(urlContains: "ssw")
        #expect(RuleMatcher.matches(match, context: RoutingContext(url: "https://mycompany.slack.com/archives/ssw-team/p123", sourceBundleId: nil)))
        #expect(RuleMatcher.matches(match, context: RoutingContext(url: "https://ssw.com.au", sourceBundleId: nil)))
        #expect(!RuleMatcher.matches(match, context: RoutingContext(url: "https://example.com", sourceBundleId: nil)))
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        let match = RoutingRule.Match(urlContains: "SSW")
        #expect(RuleMatcher.matches(match, context: RoutingContext(url: "https://ssw.com.au", sourceBundleId: nil)))

        let lowerMatch = RoutingRule.Match(urlContains: "ssw")
        #expect(RuleMatcher.matches(lowerMatch, context: RoutingContext(url: "https://SSW.com.au", sourceBundleId: nil)))
    }

    @Test("glob syntax like *ssw* is taken literally, not as a wildcard -- the whole point of this field")
    func globSyntaxIsLiteral() {
        // If a caller passes the literal string "*ssw*" (e.g. a user who
        // didn't realize this field isn't a glob), it's matched as that
        // literal substring, which will almost never appear in a real URL --
        // this documents the behavior, it's the editor's job (not the
        // matcher's) to steer people away from typing glob syntax here.
        let match = RoutingRule.Match(urlContains: "*ssw*")
        #expect(!RuleMatcher.matches(match, context: RoutingContext(url: "https://ssw.com.au", sourceBundleId: nil)))
    }
}

@Suite("Rule.Match AND semantics")
struct MatchSemanticsTests {
    @Test("all present fields must match (AND)")
    func andAcrossFields() {
        let match = RoutingRule.Match(
            urlContains: "sub",
            domainGlob: "*.example.com",
            urlRegex: "^https://",
            sourceBundleIds: ["com.tinyspeck.slackmacgap"]
        )

        // Every field satisfied.
        #expect(RuleMatcher.matches(match, context: RoutingContext(
            url: "https://sub.example.com/x", sourceBundleId: "com.tinyspeck.slackmacgap"
        )))

        // urlContains fails.
        #expect(!RuleMatcher.matches(match, context: RoutingContext(
            url: "https://other.example.com/x", sourceBundleId: "com.tinyspeck.slackmacgap"
        )))

        // Domain fails.
        #expect(!RuleMatcher.matches(match, context: RoutingContext(
            url: "https://other.com/x", sourceBundleId: "com.tinyspeck.slackmacgap"
        )))

        // Regex fails (http, not https).
        #expect(!RuleMatcher.matches(match, context: RoutingContext(
            url: "http://sub.example.com/x", sourceBundleId: "com.tinyspeck.slackmacgap"
        )))

        // Source fails.
        #expect(!RuleMatcher.matches(match, context: RoutingContext(
            url: "https://sub.example.com/x", sourceBundleId: "com.apple.mail"
        )))
    }

    @Test("a field absent from the rule is not evaluated")
    func absentFieldsAreVacuouslyTrue() {
        let sourceOnly = RoutingRule.Match(sourceBundleIds: ["com.apple.mail"])
        #expect(RuleMatcher.matches(sourceOnly, context: RoutingContext(
            url: "https://anything.example/whatever", sourceBundleId: "com.apple.mail"
        )))

        let matchEverything = RoutingRule.Match()
        #expect(RuleMatcher.matches(matchEverything, context: RoutingContext(url: "https://anything.example", sourceBundleId: nil)))
    }

    @Test("no attributable source never satisfies a sourceBundleIds constraint")
    func noSourceNeverMatchesSourceConstraint() {
        let match = RoutingRule.Match(sourceBundleIds: ["com.apple.mail"])
        #expect(!RuleMatcher.matches(match, context: RoutingContext(url: "https://example.com", sourceBundleId: nil)))
    }

    @Test("an empty sourceBundleIds list is treated as absent, not unsatisfiable")
    func emptySourceListIsVacuous() {
        let match = RoutingRule.Match(sourceBundleIds: [])
        #expect(RuleMatcher.matches(match, context: RoutingContext(url: "https://example.com", sourceBundleId: nil)))
    }

    @Test("an unparseable regex pattern is a non-match, not a crash")
    func invalidRegexIsNonMatch() {
        let match = RoutingRule.Match(urlRegex: "(unclosed")
        #expect(!RuleMatcher.matches(match, context: RoutingContext(url: "https://example.com", sourceBundleId: nil)))
    }

    @Test("an absent urlContains is vacuously true, like every other optional field")
    func absentUrlContainsIsVacuous() {
        let match = RoutingRule.Match(domainGlob: "*.example.com")
        #expect(RuleMatcher.matches(match, context: RoutingContext(url: "https://example.com/anything", sourceBundleId: nil)))
    }
}

@Suite("RoutingConfiguration migration/compat")
struct MigrationCompatTests {
    @Test("a routing.json written before urlContains existed still decodes, with urlContains nil")
    func oldShapeWithoutUrlContainsDecodes() throws {
        let oldShapeJSON = """
        {
          "rules": [
            {
              "id": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
              "match": { "domainGlob": "*.example.com" },
              "action": { "profileId": "work" }
            }
          ],
          "defaultProfileId": "default"
        }
        """
        let data = Data(oldShapeJSON.utf8)
        let decoded = try JSONDecoder().decode(RoutingConfiguration.self, from: data)

        #expect(decoded.rules.count == 1)
        #expect(decoded.rules[0].match.urlContains == nil)
        #expect(decoded.rules[0].match.domainGlob == "*.example.com")
        #expect(decoded.defaultProfileId == "default")

        // And the decoded rule still matches exactly as it did before.
        #expect(RuleMatcher.matches(decoded.rules[0].match, context: RoutingContext(url: "https://example.com", sourceBundleId: nil)))
    }

    @Test("a rule with urlContains round-trips through encode/decode")
    func urlContainsRoundTrips() throws {
        let rule = RoutingRule(match: .init(urlContains: "ssw"), action: .init(profileId: "work"))
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RoutingRule.self, from: data)
        #expect(decoded == rule)
    }
}

@Suite("Rule ordering and fallback")
struct RuleOrderingTests {
    @Test("first matching rule wins, later rules are ignored")
    func firstMatchWins() {
        let rules = [
            RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "work")),
            RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "personal")),
        ]
        let resolved = RuleMatcher.resolveProfileId(
            for: RoutingContext(url: "https://example.com", sourceBundleId: nil),
            rules: rules,
            defaultProfileId: "default"
        )
        #expect(resolved == "work")
    }

    @Test("no matching rule falls back to the default profile")
    func fallsBackToDefault() {
        let rules = [
            RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "work")),
        ]
        let resolved = RuleMatcher.resolveProfileId(
            for: RoutingContext(url: "https://other.com", sourceBundleId: nil),
            rules: rules,
            defaultProfileId: "default"
        )
        #expect(resolved == "default")
    }

    @Test("an empty rule list always falls back to the default profile")
    func emptyRuleListFallsBack() {
        let resolved = RuleMatcher.resolveProfileId(
            for: RoutingContext(url: "https://example.com", sourceBundleId: "com.apple.mail"),
            rules: [],
            defaultProfileId: "default"
        )
        #expect(resolved == "default")
    }

    @Test("a later, more specific rule can still win when earlier rules don't match")
    func laterRuleWinsWhenEarlierDont() {
        let rules = [
            RoutingRule(match: .init(domainGlob: "*.slack.com"), action: .init(profileId: "work")),
            RoutingRule(match: .init(sourceBundleIds: ["com.tinyspeck.slackmacgap"]), action: .init(profileId: "slack-links")),
        ]
        let resolved = RuleMatcher.resolveProfileId(
            for: RoutingContext(url: "https://example.com", sourceBundleId: "com.tinyspeck.slackmacgap"),
            rules: rules,
            defaultProfileId: "default"
        )
        #expect(resolved == "slack-links")
    }
}

/// `evaluate` is the shared diagnostic entry point (browser-ymx) both the
/// Routing Rules pane's "Test" affordance and the `browser route-test` CLI
/// command call -- these tests exist specifically to lock in that its
/// first-match-wins behavior, and its `.profileId` convenience, stay
/// identical to `resolveProfileId`'s own (already covered above), while
/// additionally reporting which rule (if any) actually matched.
@Suite("evaluate (rule-match diagnostics)")
struct RuleEvaluationTests {
    @Test("reports the matching rule, not just its resolved profile")
    func reportsMatchingRule() {
        let workRule = RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "work"))
        let rules = [workRule]

        let result = RuleMatcher.evaluate(
            context: RoutingContext(url: "https://example.com", sourceBundleId: nil),
            rules: rules,
            defaultProfileId: "default"
        )

        guard case .matched(let rule, let profileId) = result else {
            Issue.record("expected .matched, got \(result)")
            return
        }
        #expect(rule == workRule)
        #expect(profileId == "work")
        #expect(result.profileId == "work")
    }

    @Test("reports noMatch with the default profile when nothing matches")
    func reportsNoMatch() {
        let result = RuleMatcher.evaluate(
            context: RoutingContext(url: "https://other.com", sourceBundleId: nil),
            rules: [RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "work"))],
            defaultProfileId: "default"
        )

        guard case .noMatch(let defaultProfileId) = result else {
            Issue.record("expected .noMatch, got \(result)")
            return
        }
        #expect(defaultProfileId == "default")
        #expect(result.profileId == "default")
    }

    @Test("agrees with resolveProfileId on which profile is resolved, first-match-wins")
    func agreesWithResolveProfileId() {
        let rules = [
            RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "work")),
            RoutingRule(match: .init(domainGlob: "*.example.com"), action: .init(profileId: "personal")),
        ]
        let context = RoutingContext(url: "https://example.com", sourceBundleId: nil)

        let evaluated = RuleMatcher.evaluate(context: context, rules: rules, defaultProfileId: "default")
        let resolved = RuleMatcher.resolveProfileId(for: context, rules: rules, defaultProfileId: "default")

        #expect(evaluated.profileId == resolved)
        #expect(resolved == "work")
    }

    @Test("a matched rule whose profile is gone falls back to the configured default, not a named one")
    func existingProfileFallsBackToConfiguredDefault() {
        let matched = RuleEvaluation.matched(
            rule: RoutingRule(match: .init(domainGlob: "example.com"), action: .init(profileId: "deleted")),
            profileId: "deleted"
        )
        let existing: Set<String> = ["configured-default", "work"]

        #expect(matched.existingProfileId(configuredDefaultId: "configured-default") { existing.contains($0) } == "configured-default")
        #expect(RuleEvaluation.noMatch(defaultProfileId: "work").existingProfileId(configuredDefaultId: "work") { existing.contains($0) } == "work")
        #expect(matched.existingProfileId(configuredDefaultId: "also-deleted") { existing.contains($0) } == nil)
    }
}
