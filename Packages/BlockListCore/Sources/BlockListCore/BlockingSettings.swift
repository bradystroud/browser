import Foundation

/// Per-profile content-blocking configuration: a master `isEnabled` switch
/// and `allowlistedHosts` ("turn off blocking on this site"). Codable so it
/// can be persisted alongside a profile the same way
/// RoutingRulesStore/ProfileManager persist their own state elsewhere in
/// this app (wiring that up is Phase 2's job -- see the package README).
///
/// Deliberately separate from `BlockList`: the block list is shared/global
/// and potentially huge (100k+ entries, built once), while this is the tiny
/// bit that varies per profile -- keeping them apart means loading a large
/// list is a one-time cost independent of how many profiles exist.
public struct BlockingSettings: Codable, Equatable {
    public var isEnabled: Bool
    public var allowlistedHosts: [String]

    public init(isEnabled: Bool = true, allowlistedHosts: [String] = []) {
        self.isEnabled = isEnabled
        self.allowlistedHosts = allowlistedHosts
    }

    /// Should a request to `host` be blocked, combining this profile's
    /// settings with the shared `blockList`? Disabled -> never blocks.
    /// Allowlisted (subdomain-inclusive, same semantics as `DomainTrie`) ->
    /// never blocks, even if `host` is also in `blockList` -- the allowlist
    /// always wins. Otherwise -> whatever `blockList.contains(host:)` says.
    public func shouldBlock(host: String, blockList: BlockList) -> Bool {
        guard isEnabled else { return false }
        guard !isAllowlisted(host: host) else { return false }
        return blockList.contains(host: host)
    }

    /// Convenience overload extracting the host from a full URL string.
    /// Fails open (never blocks) for a URL with no parseable host -- e.g. a
    /// non-http scheme or a malformed string -- since silently blocking
    /// navigation on an unrecognized shape would be a much worse failure
    /// mode than not blocking an ad, matching this codebase's existing
    /// "invalid input is a non-match" convention (see RuleMatcher).
    public func shouldBlock(url: String, blockList: BlockList) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        return shouldBlock(host: host, blockList: blockList)
    }

    /// True if `host` itself, or any ancestor domain of `host`, is in
    /// `allowlistedHosts` -- the same subdomain-inclusive semantics as
    /// `DomainTrie`, so allowlisting `example.com` also un-blocks
    /// `ads.example.com`. `allowlistedHosts` is expected to stay small (a
    /// handful of per-site opt-outs), so this is a plain linear scan rather
    /// than building a whole trie for it.
    private func isAllowlisted(host: String) -> Bool {
        let hostLabels = host.lowercased().split(separator: ".")
        for entry in allowlistedHosts {
            let entryLabels = entry.lowercased().split(separator: ".")
            guard !entryLabels.isEmpty, entryLabels.count <= hostLabels.count else { continue }
            if hostLabels.suffix(entryLabels.count).elementsEqual(entryLabels) {
                return true
            }
        }
        return false
    }
}
