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

public enum RuleMatcher {
    /// First-match-wins profile resolution: walks `rules` in order, returns
    /// the action of the first one whose match fully applies, else
    /// `defaultProfileId`.
    public static func resolveProfileId(
        for context: RoutingContext,
        rules: [RoutingRule],
        defaultProfileId: String
    ) -> String {
        for rule in rules where matches(rule.match, context: context) {
            return rule.action.profileId
        }
        return defaultProfileId
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
    /// matches that exact host only. Case-insensitive, matching DNS.
    static func matchesDomainGlob(_ glob: String, host: String) -> Bool {
        let host = host.lowercased()
        let glob = glob.lowercased()
        if glob.hasPrefix("*.") {
            let suffix = String(glob.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return host == glob
    }
}
