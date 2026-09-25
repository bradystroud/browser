import Foundation

/// Compiles a shared blocked-domain list plus one profile's allowlisted
/// hosts into the JSON string
/// `WKContentRuleListStore.compileContentRuleList(forIdentifier:
/// encodedContentRuleList:completionHandler:)` expects (Apple's "content
/// blocker" rule format) -- the WebKit engine's equivalent of the CEF
/// adapter's host-matching (see BRWContentBlockerInternal.h's
/// `BRWContentBlockerShouldBlock`, and BlockListCore's
/// `BlockingSettings.shouldBlock`, which this mirrors the semantics of).
/// Pure Foundation, no WebKit dependency, so it's testable via `swift test`
/// without a WKWebView/window -- see WebKitEngineAdapter.swift for where the
/// resulting JSON actually gets compiled and attached to a
/// WKUserContentController.
///
/// One rule per blocked domain, each a `block` action on a `url-filter`
/// matching that domain and any subdomain of it (mirroring
/// BlockList/DomainTrie's subdomain-inclusive semantics via a leading
/// `([a-z0-9-]+\.)*` group), followed by a `[/:]` boundary so
/// `evil-example.com` doesn't false-positive-match a blocked `example.com`.
/// The boundary needs no `|$` alternative: WebKit matches the canonicalized
/// URL, and an http(s) URL always has at least a `/` path after its host.
/// Every filter must stay inside WebKit's regex subset (see
/// `ContentBlockerRegex`) -- `WKContentRuleListStore` rejects the whole list
/// over one bad rule, so a domain whose filter can't be made valid is
/// dropped and reported rather than emitted.
///
/// `allowlistedHosts` becomes every rule's `unless-domain` -- WebKit's own
/// per-loading-page-domain exemption -- so blocking is suppressed while
/// browsing an allowlisted site, the same "allowlist always wins, one
/// profile at a time" semantics `BlockingSettings.shouldBlock` implements
/// for CEF. This is why the compiled list is per-profile (keyed by profile
/// name in WKContentRuleListStore) rather than one shared list the way the
/// CEF side's single atomically-published snapshot is -- the allowlist
/// itself is per-profile.
public enum ContentRuleListBuilder {
    /// WebKit refuses to compile a single list with more than 150,000 rules.
    public static let webKitMaximumRulesPerList = 150_000

    /// Rules per chunk in `build(...)`. Well under WebKit's ceiling so that a
    /// chunk WebKit still rejects for some unforeseen reason costs only that
    /// chunk's rules, and each chunk compiles quickly.
    public static let defaultRulesPerList = 50_000

    public struct Output: Equatable {
        /// One JSON rule list per chunk, each independently compilable via
        /// `WKContentRuleListStore` (under its own identifier) and attachable
        /// alongside the others on one WKUserContentController. Empty when
        /// there is nothing to block.
        public let lists: [String]
        public let ruleCount: Int
        /// Domains that produced no valid rule (non-ASCII/IDN, characters a
        /// hostname can't contain, or a filter outside WebKit's subset).
        public let droppedDomains: [String]
    }

    /// Single-list convenience: every valid rule in one JSON array, or `"[]"`.
    public static func json(blockedDomains: [String], allowlistedHosts: [String]) -> String {
        build(blockedDomains: blockedDomains, allowlistedHosts: allowlistedHosts,
              maxRulesPerList: webKitMaximumRulesPerList).lists.first ?? "[]"
    }

    public static func build(
        blockedDomains: [String],
        allowlistedHosts: [String],
        maxRulesPerList: Int = defaultRulesPerList
    ) -> Output {
        let unlessDomains = allowlistedHosts.map { "*" + $0.lowercased() }
        let chunkSize = max(1, min(maxRulesPerList, webKitMaximumRulesPerList))

        var filters: [String] = []
        var dropped: [String] = []
        // Sorted and de-duplicated so the same input always yields the same
        // chunks (BlockList.allDomains() is in Set order).
        for domain in Set(blockedDomains.map { $0.lowercased() }).sorted() {
            guard let domainFilters = urlFilters(forDomain: domain) else {
                dropped.append(domain)
                continue
            }
            filters += domainFilters
        }

        var lists: [String] = []
        var start = 0
        while start < filters.count {
            let end = min(start + chunkSize, filters.count)
            let rules: [[String: Any]] = filters[start..<end].map { filter in
                var trigger: [String: Any] = ["url-filter": filter]
                if !unlessDomains.isEmpty {
                    trigger["unless-domain"] = unlessDomains
                }
                return ["trigger": trigger, "action": ["type": "block"]]
            }
            // Fails open (a missing chunk blocks nothing) rather than
            // crashing -- matches this codebase's existing "invalid input is
            // a non-match" convention (see BlockingSettings.shouldBlock's own
            // doc comment).
            if let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                lists.append(string)
            }
            start = end
        }
        return Output(lists: lists, ruleCount: filters.count, droppedDomains: dropped)
    }

    /// The valid url-filter(s) blocking `domain` and its subdomains, or nil
    /// when none can be produced.
    static func urlFilters(forDomain domain: String) -> [String]? {
        // WebKit filters are ASCII-only and Foundation has no punycode
        // conversion, so an IDN (or anything else in a list that isn't a
        // hostname) is dropped here.
        guard !domain.isEmpty,
              domain.unicodeScalars.allSatisfy({ hostnameCharacters.contains($0) }) else {
            return nil
        }
        let pattern = "^https?://([a-z0-9-]+\\.)*\(escapeRegex(domain))[/:]"
        guard let expanded = ContentBlockerRegex.expandDisjunctions(pattern) else { return nil }
        let valid = expanded.filter { ContentBlockerRegex.validate($0) == nil }
        return valid.count == expanded.count ? valid : nil
    }

    private static let hostnameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")

    /// Escapes every WebKit content-blocker regex metacharacter in `domain`
    /// so it's matched literally -- domains contain `.` (the one
    /// metacharacter that actually occurs in practice) but this covers the
    /// full metacharacter set defensively.
    private static func escapeRegex(_ domain: String) -> String {
        var result = ""
        result.reserveCapacity(domain.count)
        for char in domain {
            if ".^$*+?()[]{}|\\".contains(char) {
                result.append("\\")
            }
            result.append(char)
        }
        return result
    }
}
