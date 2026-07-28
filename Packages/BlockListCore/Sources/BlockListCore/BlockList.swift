import Foundation

/// The shared, potentially-large (100k+ entries) set of blocked domains --
/// built once (from the bundled starter list, and/or a future remote list,
/// see the package README) and shared across every profile. Per-profile
/// customization (master enable/disable, per-site allowlist) deliberately
/// lives in `BlockingSettings` instead, combined via
/// `BlockingSettings.shouldBlock(host:blockList:)` -- the block list itself
/// carries no notion of "enabled" or "allowlisted", only "is this domain in
/// the list."
public final class BlockList {
    private let trie = DomainTrie()
    // Tracked alongside the trie (not derived from it -- DomainTrie doesn't
    // support enumeration, only lookup) so callers that need the flat list
    // of every loaded domain -- e.g. Phase 2's bridge handoff, which pushes
    // this list down to BRWContentBlocker to build its own C++-side lookup
    // structure -- don't need to re-parse or otherwise reconstruct it.
    private var domains: Set<String> = []

    public init() {}

    /// Number of distinct domains currently loaded.
    public var domainCount: Int { trie.count }

    /// Every distinct domain currently loaded, in no particular order.
    public func allDomains() -> [String] {
        Array(domains)
    }

    public func addDomain(_ domain: String) {
        let countBefore = trie.count
        trie.insert(domain)
        if trie.count != countBefore {
            domains.insert(domain)
        }
    }

    /// Parses and loads every domain found in `text` (either supported
    /// format -- see `ListParser`). Returns the number of new domains
    /// added.
    @discardableResult
    public func load(_ text: String) -> Int {
        var added = 0
        for domain in ListParser.parseDomains(text) {
            let countBefore = trie.count
            trie.insert(domain)
            if trie.count != countBefore {
                domains.insert(domain)
                added += 1
            }
        }
        return added
    }

    /// Loads the bundled starter list (see `starterBlockListText`) into
    /// this instance. Convenience for "just works out of the box" callers.
    @discardableResult
    public func loadStarterList() -> Int {
        load(starterBlockListText)
    }

    /// True if `host` itself, or any ancestor domain of `host`, is in this
    /// list. Callers that need to honor a profile's enable flag or
    /// allowlist should go through `BlockingSettings.shouldBlock(host:
    /// blockList:)` instead of calling this directly.
    public func contains(host: String) -> Bool {
        trie.contains(host: host)
    }
}
