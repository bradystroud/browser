import XCTest
@testable import BrowserCore

final class EmailSuggestionRankerTests: XCTestCase {
    private let work = "alex@contoso.com.au"
    private let personal = "brady@example.com"
    private let other = "someone@contoso.com"
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let tenantGUID = "2d8a2b0e-8f7c-4c1a-9a3e-3b2f6f0a9c11"

    private func use(_ email: String, _ url: String, daysAgo: Double = 1, count: Int = 1) -> EmailUsageRecord {
        let host = URLComponents(string: url)!.host!
        return EmailUsageRecord(
            email: email, siteDomain: RegistrableDomain.of(host: host), host: host,
            tenantKey: IdentityProviderHints.parse(urlString: url).tenantKey,
            lastUsed: now.addingTimeInterval(-daysAgo * 86_400), count: count
        )
    }

    private func top(_ candidates: [String], usage: [EmailUsageRecord] = [], rules: [EmailRule] = [],
                     url: String, prefix: String = "") -> RankedEmail? {
        EmailSuggestionRanker.rank(candidates: candidates, usage: usage, rules: rules, pageURL: url, prefix: prefix).first
    }

    // Personal is used far more, so any SSW win below is the hint's doing.
    private var heavyPersonalUsage: [EmailUsageRecord] {
        [use(personal, "https://github.com/login", count: 40)]
    }

    func testMicrosoftTenantAsDomainInPath() {
        let result = top([personal, work], usage: heavyPersonalUsage,
                         url: "https://login.microsoftonline.com/ssw.com.au/oauth2/v2.0/authorize?client_id=x")
        XCTAssertEqual(result, RankedEmail(email: work, reason: .domainHint))
        XCTAssertEqual(result?.reason.label(provider: .microsoft), "Matches this Microsoft tenant")
    }

    func testDomainHintQueryParameter() {
        let result = top([personal, work], usage: heavyPersonalUsage,
                         url: "https://login.microsoftonline.com/common/oauth2/authorize?domain_hint=ssw.com.au")
        XCTAssertEqual(result, RankedEmail(email: work, reason: .domainHint))
    }

    func testLearnedTenantGUID() {
        let tenantURL = "https://login.microsoftonline.com/\(tenantGUID)/oauth2/v2.0/authorize"
        let usage = heavyPersonalUsage + [
            // Personal was used on microsoftonline.com more recently, but on another tenant.
            use(personal, "https://login.microsoftonline.com/common/oauth2/authorize", daysAgo: 0.1, count: 5),
            use(work, tenantURL, daysAgo: 10),
        ]
        let result = top([personal, work], usage: usage, url: tenantURL + "?client_id=abc")
        XCTAssertEqual(result, RankedEmail(email: work, reason: .learnedTenant))
        XCTAssertEqual(result?.reason.label(provider: .microsoft), "Used on this Microsoft tenant")
    }

    func testLoginHintExactWinsOverEverythingButRules() {
        let url = "https://login.microsoftonline.com/ssw.com.au/oauth2/authorize?login_hint=Someone%40Contoso.com"
        XCTAssertEqual(top([personal, work, other], usage: heavyPersonalUsage, url: url),
                       RankedEmail(email: other, reason: .loginHint))
    }

    func testLoginHintForUnknownAddressIsNotInvented() {
        let url = "https://accounts.google.com/o/oauth2/auth?login_hint=stranger%40nowhere.org"
        let ranked = EmailSuggestionRanker.rank(candidates: [personal], usage: [], rules: [], pageURL: url)
        XCTAssertEqual(ranked.map(\.email), [personal])
    }

    func testGoogleHostedDomain() {
        let result = top([personal, work], usage: heavyPersonalUsage,
                         url: "https://accounts.google.com/o/oauth2/v2/auth?hd=ssw.com.au&client_id=1")
        XCTAssertEqual(result, RankedEmail(email: work, reason: .domainHint))
        XCTAssertEqual(result?.reason.label(provider: .google), "Matches this Google tenant")
    }

    func testOktaSubdomainMatchesEmailDomainLabel() {
        XCTAssertEqual(top([personal, work], usage: heavyPersonalUsage, url: "https://ssw.okta.com/login/login.htm"),
                       RankedEmail(email: work, reason: .domainHint))
    }

    func testSiteDomainMatch() {
        XCTAssertEqual(top([personal, work], usage: heavyPersonalUsage, url: "https://timepro.ssw.com.au/signin"),
                       RankedEmail(email: work, reason: .siteDomain))
    }

    func testUsedOnThisSiteMostRecentFirst() {
        let usage = [
            use(work, "https://www.example.org/login", daysAgo: 5, count: 9),
            use(other, "https://accounts.example.org/login", daysAgo: 1),
        ]
        let ranked = EmailSuggestionRanker.rank(candidates: [personal], usage: usage, rules: [],
                                                pageURL: "https://example.org/signin")
        XCTAssertEqual(ranked.map(\.email), [other, work, personal])
        XCTAssertEqual(ranked.first?.reason, .usedOnSite)
    }

    func testNoHintsFallsBackToFrequency() {
        let usage = [
            use(work, "https://a.com/", count: 2),
            use(personal, "https://b.com/", count: 7),
            use(other, "https://c.com/", count: 4),
        ]
        let ranked = EmailSuggestionRanker.rank(candidates: [], usage: usage, rules: [], pageURL: "https://unrelated.net/")
        XCTAssertEqual(ranked.map(\.email), [personal, other, work])
        XCTAssertEqual(Set(ranked.map(\.reason)), [.frequency])
        XCTAssertNil(EmailRankReason.frequency.label(provider: nil))
    }

    func testRuleBeatsHints() {
        let rules = [EmailRule(hostPattern: "login.microsoftonline.com", tenant: "ssw.com.au", email: personal)]
        let url = "https://login.microsoftonline.com/ssw.com.au/oauth2/authorize?login_hint=\(work)"
        XCTAssertEqual(top([work], rules: rules, url: url), RankedEmail(email: personal, reason: .rule))
    }

    func testRuleWithTenantOnlyMatchesThatTenant() {
        let rules = [EmailRule(hostPattern: "login.microsoftonline.com", tenant: tenantGUID, email: other)]
        XCTAssertNotEqual(top([personal], rules: rules, url: "https://login.microsoftonline.com/common/oauth2/authorize")?.reason, .rule)
        XCTAssertEqual(top([personal], rules: rules, url: "https://login.microsoftonline.com/\(tenantGUID)/saml2")?.email, other)
    }

    func testMostSpecificRuleWins() {
        let rules = [
            EmailRule(hostPattern: "*", email: personal),
            EmailRule(hostPattern: "*.ssw.com.au", email: work),
        ]
        XCTAssertEqual(top([], rules: rules, url: "https://ssw.com.au/")?.email, work, "*.x also matches bare x")
        XCTAssertEqual(top([], rules: rules, url: "https://github.com/")?.email, personal)
    }

    func testPrefixFilterIsCaseInsensitiveAndLimited() {
        let many = (0..<9).map { "user\($0)@example.com" }
        XCTAssertEqual(EmailSuggestionRanker.rank(candidates: many, usage: [], rules: [], pageURL: "https://x.com/").count, 5)
        let filtered = EmailSuggestionRanker.rank(candidates: [personal, work], usage: [], rules: [], pageURL: "https://x.com/", prefix: "BRADYS")
        XCTAssertEqual(filtered.map(\.email), [work])
    }

    func testDuplicatesAndInvalidCandidatesAreDropped() {
        let ranked = EmailSuggestionRanker.rank(candidates: ["Brady@Example.com", personal, "not an email", "x@y"],
                                                usage: [], rules: [], pageURL: "https://x.com/")
        XCTAssertEqual(ranked.map(\.email), [personal])
    }

    func testGlob() {
        XCTAssertTrue(EmailSuggestionRanker.glob("*.okta.com", matches: "ssw.okta.com"))
        XCTAssertTrue(EmailSuggestionRanker.glob("github.com/orgs/*", matches: "github.com/orgs/ssw"))
        XCTAssertFalse(EmailSuggestionRanker.glob("*.okta.com", matches: "ssw.okta.com.evil.net"))
        XCTAssertFalse(EmailSuggestionRanker.glob("a*c", matches: "abd"))
    }
}

final class IdentityProviderHintsTests: XCTestCase {
    func testMicrosoftTenantForms() {
        let guid = "2d8a2b0e-8f7c-4c1a-9a3e-3b2f6f0a9c11"
        XCTAssertEqual(IdentityProviderHints.parse(urlString: "https://login.microsoftonline.com/\(guid.uppercased())/oauth2").tenantKey,
                       "microsoft:\(guid)")
        let byDomain = IdentityProviderHints.parse(urlString: "https://login.windows.net/ssw.com.au/oauth2/authorize")
        XCTAssertEqual(byDomain.tenantKey, "microsoft:ssw.com.au")
        XCTAssertEqual(byDomain.domainHints, ["ssw.com.au"])
        XCTAssertNil(IdentityProviderHints.parse(urlString: "https://login.microsoftonline.com/common/oauth2/authorize").tenantKey)
        XCTAssertNil(IdentityProviderHints.parse(urlString: "https://login.live.com/login.srf?wa=1").tenantKey)
        XCTAssertEqual(IdentityProviderHints.parse(urlString: "https://login.microsoftonline.com/common/x?whr=ssw.com.au").domainHints,
                       ["ssw.com.au"])
    }

    func testHintsOnlyFromTheirOwnHosts() {
        let fake = IdentityProviderHints.parse(urlString: "https://evil.example/ssw.com.au/oauth2")
        XCTAssertNil(fake.tenantKey)
        XCTAssertNil(fake.provider)
    }

    func testAuth0RegionalSubdomain() {
        let hints = IdentityProviderHints.parse(urlString: "https://ssw.au.auth0.com/login")
        XCTAssertEqual(hints.provider, .auth0)
        XCTAssertEqual(hints.tenantKey, "auth0:ssw")
    }
}

final class RegistrableDomainTests: XCTestCase {
    func testCommonShapes() {
        XCTAssertEqual(RegistrableDomain.of(host: "login.ssw.com.au"), "ssw.com.au")
        XCTAssertEqual(RegistrableDomain.of(host: "ssw.com.au"), "ssw.com.au")
        XCTAssertEqual(RegistrableDomain.of(host: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(RegistrableDomain.of(host: "login.microsoftonline.com"), "microsoftonline.com")
        XCTAssertEqual(RegistrableDomain.of(host: "a.b.example.io"), "example.io")
        XCTAssertEqual(RegistrableDomain.of(host: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(RegistrableDomain.of(host: "localhost"), "localhost")
    }
}

final class EmailAutofillStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testRecordUseAggregatesAndPersists() {
        let store = EmailAutofillStore(profileDirectory: dir)
        let url = "https://login.microsoftonline.com/ssw.com.au/oauth2/authorize"
        XCTAssertTrue(store.recordUse(email: " Alex@Contoso.com.au ", pageURL: url))
        XCTAssertTrue(store.recordUse(email: "alex@contoso.com.au", pageURL: url))
        XCTAssertFalse(store.recordUse(email: "nope", pageURL: url))

        let reloaded = EmailAutofillStore(profileDirectory: dir)
        XCTAssertEqual(reloaded.data.usage.count, 1)
        let record = reloaded.data.usage[0]
        XCTAssertEqual(record.email, "alex@contoso.com.au")
        XCTAssertEqual(record.count, 2)
        XCTAssertEqual(record.siteDomain, "microsoftonline.com")
        XCTAssertEqual(record.tenantKey, "microsoft:ssw.com.au")
    }

    func testAddressesRulesAndClear() {
        let store = EmailAutofillStore(profileDirectory: dir)
        XCTAssertTrue(store.addAddress("Me@Example.com"))
        XCTAssertFalse(store.addAddress("me@example.com"))
        let rule = EmailRule(hostPattern: "*.ssw.com.au", email: "me@example.com")
        store.saveRule(rule)
        store.recordUse(email: "me@example.com", pageURL: "https://a.com/")
        store.clearUsage()

        let reloaded = EmailAutofillStore(profileDirectory: dir)
        XCTAssertEqual(reloaded.data.addresses, ["me@example.com"])
        XCTAssertEqual(reloaded.data.rules, [rule])
        XCTAssertTrue(reloaded.data.usage.isEmpty)
        reloaded.removeRule(id: rule.id)
        reloaded.removeAddress("me@example.com")
        XCTAssertEqual(EmailAutofillStore(profileDirectory: dir).data, EmailAutofillData())
    }

    func testNonPersistentStoreNeverWrites() throws {
        let store = EmailAutofillStore(profileDirectory: dir, persistent: false)
        store.recordUse(email: "me@example.com", pageURL: "https://a.com/")
        store.addAddress("me@example.com")
        XCTAssertEqual(store.data.usage.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testUsageIsCapped() {
        let store = EmailAutofillStore(profileDirectory: dir, persistent: false)
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0...EmailAutofillStore.maximumUsageRecords {
            store.recordUse(email: "u@example.com", pageURL: "https://h\(i).example.com/", at: base.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.data.usage.count, EmailAutofillStore.maximumUsageRecords)
        XCTAssertFalse(store.data.usage.contains { $0.host == "h0.example.com" }, "the oldest record is the one pruned")
    }
}
