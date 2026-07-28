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

    public init() {}

    /// Number of distinct domains currently loaded.
    public var domainCount: Int { trie.count }

    public func addDomain(_ domain: String) {
        trie.insert(domain)
    }

    /// Parses and loads every domain found in `text` (either supported
    /// format -- see `ListParser`). Returns the number of new domains
    /// added.
    @discardableResult
    public func load(_ text: String) -> Int {
        ListParser.parse(text, into: trie)
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
