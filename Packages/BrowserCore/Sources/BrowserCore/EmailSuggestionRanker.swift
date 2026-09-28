import Foundation

/// One remembered use of an email address: the address was committed in a
/// form on `host`. Aggregated per (email, host, tenant) so a daily sign-in
/// is one record with a growing count, not a record per day.
public struct EmailUsageRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var email: String
    /// Registrable domain of `host` -- "this site".
    public var siteDomain: String
    public var host: String
    /// `IdentityProviderHints.tenantKey` of the page it was used on, if any.
    public var tenantKey: String?
    public var lastUsed: Date
    public var count: Int

    public init(id: String = UUID().uuidString, email: String, siteDomain: String, host: String,
                tenantKey: String?, lastUsed: Date, count: Int) {
        self.id = id
        self.email = email
        self.siteDomain = siteDomain
        self.host = host
        self.tenantKey = tenantKey
        self.lastUsed = lastUsed
        self.count = count
    }
}

/// A user-written rule: on pages matching `hostPattern` (and, when set,
/// signing in to `tenant`), suggest `email` first.
public struct EmailRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// A glob (`*` wildcard) matched against the host, or against
    /// host + path when it contains a `/`: `*.contoso.com.au`,
    /// `login.microsoftonline.com`, `github.com/orgs/*`.
    public var hostPattern: String
    /// A tenant GUID, tenant domain or Okta/Auth0 subdomain; nil or empty
    /// for any tenant.
    public var tenant: String?
    public var email: String

    public init(id: String = UUID().uuidString, hostPattern: String, tenant: String? = nil, email: String) {
        self.id = id
        self.hostPattern = hostPattern
        self.tenant = tenant
        self.email = email
    }
}

/// Why an email was placed where it was -- the strongest signal it matched.
/// Cases are declared strongest first; that order *is* the ranking.
public enum EmailRankReason: Int, Comparable, Sendable {
    case rule
    case loginHint
    case learnedTenant
    case domainHint
    case usedOnSite
    case siteDomain
    case frequency

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The short label shown beside the top suggestion, or nil for the
    /// reasons that need no explanation.
    public func label(provider: IdentityProviderHints.Provider?) -> String? {
        let tenantName = provider.map { "\($0.displayName) tenant" } ?? "sign-in tenant"
        switch self {
        case .rule: return "Your rule for this site"
        case .loginHint: return "Requested by this sign-in page"
        case .learnedTenant: return "Used on this \(tenantName)"
        case .domainHint: return "Matches this \(tenantName)"
        case .usedOnSite: return "Used on this site"
        case .siteDomain: return "Matches this site's domain"
        case .frequency: return nil
        }
    }
}

public struct RankedEmail: Equatable, Sendable {
    public let email: String
    public let reason: EmailRankReason
}

/// Orders candidate email addresses for the email field the user just
/// focused. Pure: everything it knows arrives as arguments, and the page URL
/// must be the engine's verified URL for the tab, never a page-reported one.
///
/// Order, strongest first:
///  1. a user rule that matches this page (most specific rule wins);
///  2. `login_hint` naming the exact address;
///  3. the address last used with this identity-provider tenant;
///  4. an address in a domain the URL hints at (`domain_hint`, `whr`, `hd`,
///     a Microsoft tenant written as a domain, an Okta/Auth0 subdomain);
///  5. an address used on this site before, most recent first;
///  6. an address whose domain is this site's own domain;
///  7. everything else, by how often it has been used in this profile.
///
/// Hints and tenants rank above plain site history on purpose: on a shared
/// sign-in host such as login.microsoftonline.com every tenant is "the same
/// site", so site history alone would offer the personal account on the
/// work tenant's page.
public enum EmailSuggestionRanker {
    public static func rank(
        candidates: [String],
        usage: [EmailUsageRecord],
        rules: [EmailRule],
        pageURL: String,
        prefix: String = "",
        limit: Int = 5
    ) -> [RankedEmail] {
        let components = URLComponents(string: pageURL)
        let host = components?.host?.lowercased() ?? ""
        let path = components?.path ?? ""
        let site = RegistrableDomain.of(host: host)
        let hints = IdentityProviderHints.parse(urlString: pageURL)

        var pool: [String] = []
        var seen: Set<String> = []
        func add(_ raw: String) {
            guard let email = EmailAddress.normalized(raw), seen.insert(email).inserted else { return }
            pool.append(email)
        }
        candidates.forEach(add)
        usage.forEach { add($0.email) }

        // Rules: matching ones, most specific first. A rule may name an
        // address no other source knows; it still becomes a candidate.
        let matchingRules = rules.enumerated()
            .filter { matches(rule: $0.element, host: host, path: path, hints: hints) }
            .sorted { lhs, rhs in
                let l = specificity(lhs.element), r = specificity(rhs.element)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
        var ruleRank: [String: Int] = [:]
        for (index, rule) in matchingRules.enumerated() {
            guard let email = EmailAddress.normalized(rule.email) else { continue }
            add(email)
            if ruleRank[email] == nil { ruleRank[email] = index }
        }

        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? pool : pool.filter { $0.hasPrefix(needle) }

        struct Score {
            let email: String
            let reason: EmailRankReason
            /// Tie-break within the reason: lower sorts first.
            let order: Double
            let totalCount: Int
            let lastUsed: Date
        }

        let scores: [Score] = filtered.map { email in
            let records = usage.filter { EmailAddress.normalized($0.email) == email }
            let totalCount = records.reduce(0) { $0 + $1.count }
            let lastUsed = records.map(\.lastUsed).max() ?? .distantPast
            let domain = EmailAddress.domain(of: email)

            if let rank = ruleRank[email] {
                return Score(email: email, reason: .rule, order: Double(rank), totalCount: totalCount, lastUsed: lastUsed)
            }
            if hints.loginHint == email {
                return Score(email: email, reason: .loginHint, order: 0, totalCount: totalCount, lastUsed: lastUsed)
            }
            if let tenant = hints.tenantKey,
               let latest = records.filter({ $0.tenantKey == tenant }).map(\.lastUsed).max() {
                return Score(email: email, reason: .learnedTenant, order: -latest.timeIntervalSinceReferenceDate,
                             totalCount: totalCount, lastUsed: lastUsed)
            }
            if hints.domainHints.contains(where: { RegistrableDomain.host(domain, isWithin: $0) })
                || hints.tenantLabels.contains(where: { RegistrableDomain.of(host: domain).split(separator: ".").first.map(String.init) == $0 }) {
                return Score(email: email, reason: .domainHint, order: -Double(totalCount), totalCount: totalCount, lastUsed: lastUsed)
            }
            if !site.isEmpty, let latest = records.filter({ $0.siteDomain == site }).map(\.lastUsed).max() {
                return Score(email: email, reason: .usedOnSite, order: -latest.timeIntervalSinceReferenceDate,
                             totalCount: totalCount, lastUsed: lastUsed)
            }
            if !site.isEmpty, RegistrableDomain.of(host: domain) == site {
                return Score(email: email, reason: .siteDomain, order: -Double(totalCount), totalCount: totalCount, lastUsed: lastUsed)
            }
            return Score(email: email, reason: .frequency, order: -Double(totalCount), totalCount: totalCount, lastUsed: lastUsed)
        }

        let sorted = scores.sorted { a, b in
            if a.reason != b.reason { return a.reason < b.reason }
            if a.order != b.order { return a.order < b.order }
            if a.totalCount != b.totalCount { return a.totalCount > b.totalCount }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            return a.email < b.email
        }
        return sorted.prefix(max(0, limit)).map { RankedEmail(email: $0.email, reason: $0.reason) }
    }

    // MARK: - Rules

    static func matches(rule: EmailRule, host: String, path: String, hints: IdentityProviderHints) -> Bool {
        let pattern = rule.hostPattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty, !host.isEmpty else { return false }
        let subject = pattern.contains("/") ? host + (path.isEmpty ? "/" : path.lowercased()) : host
        guard glob(pattern, matches: subject) else { return false }
        guard let tenant = rule.tenant?.trimmingCharacters(in: .whitespaces).lowercased(), !tenant.isEmpty else {
            return true
        }
        let tenantValue = hints.tenantKey.flatMap { key in key.split(separator: ":", maxSplits: 1).last.map(String.init) }
        return tenantValue == tenant || hints.domainHints.contains(tenant) || hints.tenantLabels.contains(tenant)
    }

    /// A tenant-scoped rule is more specific than any rule without one; then
    /// the more literal characters, the more specific.
    private static func specificity(_ rule: EmailRule) -> Int {
        let hasTenant = !(rule.tenant ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let literal = rule.hostPattern.filter { $0 != "*" }.count
        return (hasTenant ? 10_000 : 0) + literal
    }

    /// `*` matches any run of characters (including none); everything else
    /// matches itself. `*.contoso.com.au` also matches the bare `contoso.com.au`,
    /// which is what anyone writing it means.
    static func glob(_ pattern: String, matches subject: String) -> Bool {
        if pattern.hasPrefix("*."), subject == pattern.dropFirst(2) { return true }
        let p = Array(pattern), s = Array(subject)
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] != "*", p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
