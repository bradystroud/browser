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

    @Test("host extraction from a URL string")
    func hostExtraction() {
        #expect(RuleMatcher.host(of: "https://sub.example.com/path?q=1") == "sub.example.com")
        #expect(RuleMatcher.host(of: "not a url") == nil)
    }
}

@Suite("Rule.Match AND semantics")
struct MatchSemanticsTests {
    @Test("all present fields must match (AND)")
    func andAcrossFields() {
        let match = RoutingRule.Match(
            domainGlob: "*.example.com",
            urlRegex: "^https://",
            sourceBundleIds: ["com.tinyspeck.slackmacgap"]
        )

        // Every field satisfied.
        #expect(RuleMatcher.matches(match, context: RoutingContext(
            url: "https://sub.example.com/x", sourceBundleId: "com.tinyspeck.slackmacgap"
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
