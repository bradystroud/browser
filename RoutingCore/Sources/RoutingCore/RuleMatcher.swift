import Foundation

/// Everything about an incoming link that a rule can match against: the URL
/// itself, and the resolved source app's bundle identifier (nil if there is
/// no attributable sender -- see docs/research/2026-07-27-link-routing-macos.md
/// section 3 on keySenderPIDAttr resolving to nil).
public struct RoutingContext {
    public let url: String
    public let sourceBundleId: String?

    public init(url: String, sourceBundleId: String?) {
        self.url = url
        self.sourceBundleId = sourceBundleId
    }
}

/// The result of evaluating a link against the full rule list -- which
/// rule (if any) matched, alongside the profile it resolves to either way.
/// This is the one shared entry point for anything that needs to explain
/// *why* a link resolved where it did, not just the resolved profile id:
/// the Routing Rules pane's "Test" affordance (Sources/App/Routing) and the
/// `browser route-test` CLI command (m4-webkit, Packages/BrowserCLIProtocol
/// + the app's CLIServer) both evaluate against this same function rather
/// than each re-deriving first-match-wins logic independently, which would
/// risk the CLI and the in-app diagnostics silently disagreeing about which
/// rule matched.
public enum RuleEvaluation: Equatable {
    case matched(rule: RoutingRule, profileId: String)
    case noMatch(defaultProfileId: String)

    /// The profile this evaluation resolves to either way -- what
    /// `resolveProfileId` itself returns.
    public var profileId: String {
        switch self {
        case .matched(_, let profileId): return profileId
        case .noMatch(let defaultProfileId): return defaultProfileId
        }
    }

    /// The resolved profile if it still exists, else the configured default,
    /// else nil. A rule can outlive the profile it points at, and the app and
    /// `browser route-test` must pick the same replacement.
    public func existingProfileId(configuredDefaultId: String, exists: (String) -> Bool) -> String? {
        [profileId, configuredDefaultId].first(where: exists)
    }
}

public enum RuleMatcher {
    /// First-match-wins profile resolution: walks `rules` in order, returns
    /// the action of the first one whose match fully applies, else
    /// `defaultProfileId`. A thin wrapper around `evaluate(context:rules:
    /// defaultProfileId:)` for callers (RoutingCoordinator) that only need
    /// the resolved profile, not which rule (if any) produced it.
    public static func resolveProfileId(
        for context: RoutingContext,
        rules: [RoutingRule],
        defaultProfileId: String
    ) -> String {
        evaluate(context: context, rules: rules, defaultProfileId: defaultProfileId).profileId
    }

    /// Same first-match-wins walk as `resolveProfileId`, but reports which
    /// rule matched (or that none did) -- see `RuleEvaluation`'s own doc
    /// comment for why this, not `resolveProfileId`, is the entry point
    /// diagnostic tooling should call.
    public static func evaluate(
        context: RoutingContext,
        rules: [RoutingRule],
        defaultProfileId: String
    ) -> RuleEvaluation {
        for rule in rules where matches(rule.match, context: context) {
            return .matched(rule: rule, profileId: rule.action.profileId)
        }
        return .noMatch(defaultProfileId: defaultProfileId)
    }

    /// AND across every present (non-nil) field of `match`; absent fields
    /// are not evaluated at all.
    public static func matches(_ match: RoutingRule.Match, context: RoutingContext) -> Bool {
        if let substring = match.urlContains {
            guard context.url.range(of: substring, options: .caseInsensitive) != nil else {
                return false
            }
        }

        if let glob = match.domainGlob {
            guard let host = host(of: context.url), matchesDomainGlob(glob, host: host) else {
                return false
            }
        }

        if let pattern = match.urlRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return false
            }
            let fullRange = NSRange(context.url.startIndex..<context.url.endIndex, in: context.url)
            guard regex.firstMatch(in: context.url, range: fullRange) != nil else {
                return false
            }
        }

        if let sourceBundleIds = match.sourceBundleIds, !sourceBundleIds.isEmpty {
            guard let sourceBundleId = context.sourceBundleId,
                  sourceBundleIds.contains(sourceBundleId) else {
                return false
            }
        }

        return true
    }

    static func host(of urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    /// `*.example.com` matches `example.com` and any subdomain
    /// (`www.example.com`, `a.b.example.com`, ...); a bare `example.com`
    /// matches that exact host only. Case-insensitive, matching DNS, and
    /// both sides are normalized first -- see `normalizedDomain`.
    static func matchesDomainGlob(_ glob: String, host: String) -> Bool {
        let host = normalizedDomain(host)
        if glob.hasPrefix("*.") {
            let suffix = normalizedDomain(String(glob.dropFirst(2)))
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return host == normalizedDomain(glob)
    }

    /// Lowercased ASCII (punycode) form with one trailing dot removed.
    /// `URL.host` always yields punycode (`xn--bcher-kva.de`), while a rule
    /// is typed the way the name reads (`bücher.de`), and the fully
    /// qualified `example.com.` names the same host as `example.com`.
    /// Foundation's own URL parser does the IDNA conversion, since it is the
    /// same parser that produced the host being compared against.
    static func normalizedDomain(_ domain: String) -> String {
        var domain = domain.lowercased()
        if domain.hasSuffix(".") { domain.removeLast() }
        if !domain.allSatisfy(\.isASCII),
           let ascii = URL(string: "https://" + domain)?.host {
            domain = ascii.lowercased()
        }
        return domain
    }
}
