import Foundation
import Testing
@testable import RoutingCore

@Suite("Engine site patterns")
struct EngineSitePatternTests {
    @Test("a bare domain covers the site and its subdomains")
    func domainCoversSubdomains() throws {
        let pattern = try #require(EngineSitePattern("netflix.com"))
        #expect(pattern.matches(host: "netflix.com", path: "/"))
        #expect(pattern.matches(host: "www.netflix.com", path: "/browse"))
        #expect(pattern.matches(host: "WWW.Netflix.COM", path: "/"))
        #expect(!pattern.matches(host: "notnetflix.com", path: "/"))
        #expect(!pattern.matches(host: "netflix.com.evil.com", path: "/"))
    }

    @Test("a leading *. and a scheme are accepted")
    func wildcardAndScheme() throws {
        #expect(try #require(EngineSitePattern("*.max.com")).domain == "max.com")
        #expect(try #require(EngineSitePattern("https://tv.apple.com/")).domain == "tv.apple.com")
        #expect(EngineSitePattern("file:///tmp") == nil)
        #expect(EngineSitePattern("") == nil)
        #expect(EngineSitePattern("*") == nil)
        #expect(EngineSitePattern("a*b.com") == nil)
    }

    @Test("a path prefix matches whole path segments only")
    func pathPrefix() throws {
        let pattern = try #require(EngineSitePattern("amazon.com/gp/video"))
        #expect(pattern.pathPrefix == "/gp/video")
        #expect(pattern.matches(host: "www.amazon.com", path: "/gp/video"))
        #expect(pattern.matches(host: "www.amazon.com", path: "/gp/video/detail/123"))
        #expect(pattern.matches(host: "www.amazon.com", path: "/GP/Video/storefront"))
        #expect(!pattern.matches(host: "www.amazon.com", path: "/gp/videos"))
        #expect(!pattern.matches(host: "www.amazon.com", path: "/dp/B000"))
        #expect(!pattern.matches(host: "www.amazon.com", path: ""))
    }

    @Test("an internationalized pattern matches the punycode host")
    func idn() throws {
        let pattern = try #require(EngineSitePattern("bücher.de"))
        #expect(pattern.matches(host: "xn--bcher-kva.de", path: "/"))
    }
}

@Suite("Engine rule matching")
struct EngineRuleMatcherTests {
    let rules = [
        EngineSiteRule(id: "a", pattern: "example.com", engine: .webkit),
        EngineSiteRule(id: "b", pattern: "example.com", engine: .chromium),
        EngineSiteRule(id: "c", pattern: "off.example.org", engine: .webkit, isEnabled: false),
    ]

    @Test("first enabled match wins")
    func firstMatchWins() {
        #expect(EngineRuleMatcher.matchingRule(for: "https://www.example.com/x", in: rules)?.id == "a")
        #expect(EngineRuleMatcher.matchingRule(for: "https://off.example.org/", in: rules) == nil)
    }

    @Test("only http(s) URLs match")
    func onlyWeb() {
        #expect(EngineRuleMatcher.matchingRule(for: "data:text/html,example.com", in: rules) == nil)
        #expect(EngineRuleMatcher.matchingRule(for: "about:blank", in: rules) == nil)
        #expect(EngineRuleMatcher.matchingRule(for: "http://example.com", in: rules)?.id == "a")
    }

    @Test("built-in streaming rules send DRM sites to WebKit")
    func builtIns() {
        let rules = EngineRuleConfiguration().effectiveRules
        for url in [
            "https://www.netflix.com/watch/1", "https://www.disneyplus.com/", "https://play.max.com/",
            "https://www.primevideo.com/", "https://www.amazon.com/gp/video/storefront",
            "https://tv.apple.com/us/show/x", "https://open.spotify.com/track/1",
        ] {
            #expect(EngineRuleMatcher.matchingRule(for: url, in: rules)?.engine == .webkit, "\(url)")
        }
        #expect(EngineRuleMatcher.matchingRule(for: "https://www.amazon.com/dp/B0001", in: rules) == nil)
        #expect(EngineRuleMatcher.matchingRule(for: "https://www.spotify.com/", in: rules) == nil)
    }

    @Test("a disabled built-in no longer matches, and user rules come first")
    func configurationOrder() {
        var config = EngineRuleConfiguration(disabledBuiltInIds: ["builtin.netflix"])
        #expect(EngineRuleMatcher.matchingRule(for: "https://netflix.com", in: config.effectiveRules) == nil)
        config.disabledBuiltInIds = []
        config.userRules = [EngineSiteRule(id: "mine", pattern: "netflix.com", engine: .chromium)]
        #expect(EngineRuleMatcher.matchingRule(for: "https://netflix.com", in: config.effectiveRules)?.id == "mine")
    }

    @Test("configuration round-trips through JSON")
    func codable() throws {
        let config = EngineRuleConfiguration(
            userRules: [EngineSiteRule(id: "x", pattern: "a.com/b", engine: .webkit, isEnabled: false)],
            disabledBuiltInIds: ["builtin.max"])
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(EngineRuleConfiguration.self, from: data) == config)
        #expect(String(decoding: data, as: UTF8.self).contains("\"cef\"") == false)
        #expect(String(decoding: try JSONEncoder().encode(SiteEngine.chromium), as: UTF8.self) == "\"cef\"")
    }
}

@Suite("Engine switch policy")
struct EngineSwitchPolicyTests {
    let rules = [EngineSiteRule(id: "nf", pattern: "netflix.com", engine: .webkit)]

    func decide(_ url: String, _ trigger: EngineNavigationTrigger, current: SiteEngine?,
                override: EngineOverride? = nil, defaultEngine: SiteEngine = .chromium) -> EngineDecision {
        EngineSwitchPolicy.decide(url: url, trigger: trigger, currentEngine: current,
                                  override: override, rules: rules, defaultEngine: defaultEngine)
    }

    @Test("a rule decides for every trigger")
    func ruleWins() {
        for trigger in [EngineNavigationTrigger.newTab, .explicitLoad, .pageNavigation] {
            let decision = decide("https://www.netflix.com/", trigger, current: .chromium)
            #expect(decision.engine == .webkit)
            #expect(decision.rule?.id == "nf")
        }
    }

    @Test("without a rule, new tabs and explicit loads use the default")
    func defaultEngine() {
        #expect(decide("https://example.com", .newTab, current: nil).engine == .chromium)
        #expect(decide("https://example.com", .explicitLoad, current: .webkit).engine == .chromium)
        #expect(decide("https://example.com", .newTab, current: nil, defaultEngine: .webkit).engine == .webkit)
    }

    @Test("a page's own navigation off a ruled site stays in its engine")
    func pageNavigationIsSticky() {
        #expect(decide("https://pay.example.com", .pageNavigation, current: .webkit).engine == .webkit)
        #expect(decide("https://pay.example.com", .pageNavigation, current: .chromium, defaultEngine: .webkit).engine == .chromium)
    }

    @Test("non-web URLs stay where they are")
    func nonWeb() {
        #expect(decide("data:text/html,hi", .explicitLoad, current: .webkit).engine == .webkit)
        #expect(decide("about:blank", .newTab, current: nil, defaultEngine: .webkit).engine == .webkit)
    }

    @Test("an override beats rules on its own site and for page navigations")
    func overrideHolds() {
        let override = EngineOverride(engine: .chromium, url: "https://www.netflix.com/browse")
        let sameSite = decide("https://www.netflix.com/watch/1", .explicitLoad, current: .chromium, override: override)
        #expect(sameSite.engine == .chromium)
        #expect(!sameSite.clearsOverride)
        let bare = decide("https://netflix.com/", .explicitLoad, current: .chromium, override: override)
        #expect(bare.engine == .chromium)
        let inPage = decide("https://elsewhere.com/", .pageNavigation, current: .chromium,
                            override: override, defaultEngine: .webkit)
        #expect(inPage.engine == .chromium)
        #expect(!inPage.clearsOverride)
    }

    @Test("an explicit load elsewhere drops the override")
    func overrideDropped() {
        let override = EngineOverride(engine: .webkit, url: "https://example.com/")
        let decision = decide("https://other.com/", .explicitLoad, current: .webkit, override: override)
        #expect(decision.engine == .chromium)
        #expect(decision.clearsOverride)
        let startPageOverride = EngineOverride(engine: .webkit, url: "data:text/html,start")
        #expect(startPageOverride.host == nil)
        #expect(decide("https://other.com/", .explicitLoad, current: .webkit, override: startPageOverride).clearsOverride)
    }

    @Test("the swap throttle stops a ping-pong")
    func throttle() {
        var throttle = EngineSwapThrottle(limit: 3, window: 10)
        let results = [0, 1, 2, 3, 11.5].map { throttle.allow(at: $0) }
        #expect(results == [true, true, true, false, true])
    }
}
