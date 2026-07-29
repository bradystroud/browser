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
/// `([a-z0-9-]+\.)*` group, and a trailing `path/port-or-end` group so
/// `evil-example.com` doesn't false-positive-match a blocked `example.com`).
/// `allowlistedHosts` becomes every rule's `unless-domain` -- WebKit's own
/// per-loading-page-domain exemption -- so blocking is suppressed while
/// browsing an allowlisted site, the same "allowlist always wins, one
/// profile at a time" semantics `BlockingSettings.shouldBlock` implements
/// for CEF. This is why the compiled list is per-profile (keyed by profile
/// name in WKContentRuleListStore) rather than one shared list the way the
/// CEF side's single atomically-published snapshot is -- the allowlist
/// itself is per-profile.
public enum ContentRuleListBuilder {
    public static func json(blockedDomains: [String], allowlistedHosts: [String]) -> String {
        guard !blockedDomains.isEmpty else { return "[]" }

        let unlessDomains = allowlistedHosts.map { "*" + $0.lowercased() }

        let rules: [[String: Any]] = blockedDomains.map { domain in
            var trigger: [String: Any] = [
                "url-filter": "^https?://([a-z0-9-]+\\.)*\(escapeRegex(domain.lowercased()))([/:]|$)",
            ]
            if !unlessDomains.isEmpty {
                trigger["unless-domain"] = unlessDomains
            }
            return ["trigger": trigger, "action": ["type": "block"]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            // Fails open (an empty rule list blocks nothing) rather than
            // crashing -- matches this codebase's existing "invalid input is
            // a non-match" convention (see BlockingSettings.shouldBlock's own
            // doc comment).
            return "[]"
        }
        return string
    }

    /// Escapes every WebKit content-blocker regex metacharacter in `domain`
    /// (a plain hostname, e.g. "ads.example.com") so it's matched literally
    /// -- domains contain `.` (the one metacharacter that actually occurs in
    /// practice) but this covers the full metacharacter set defensively.
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
