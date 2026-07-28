import Foundation

/// A reversed-label trie over domain names, answering "is host H, or any
/// ancestor domain of H, present in this set?" in O(number of labels in H)
/// -- independent of how many domains are stored (100k+), with memory
/// shared across common suffixes (every ".com" entry shares one "com"
/// node, every "*.doubleclick.net" query shares the "net" -> "doubleclick"
/// path).
///
/// Domains are stored root-label-first (so `ads.example.com` walks the
/// trie `com` -> `example` -> `ads`). That single storage order is what
/// makes a lookup for any host also check every one of its ancestor
/// domains along the same walk: if `example.com` was inserted, a query for
/// `ads.example.com` finds a terminal node after just two of its three
/// labels and returns true immediately, without `ads.example.com` (or
/// `ads`) ever needing to be a stored entry itself. This is the "exact
/// hosts and subdomain-inclusive entries" behavior in one lookup pass --
/// insert an exact domain, and every subdomain of it is blocked for free;
/// a shorter/parent domain is never implicitly blocked by a longer one.
public final class DomainTrie {
    private final class Node {
        var children: [String: Node] = [:]
        var isTerminal = false
    }

    private let root = Node()

    /// Number of distinct domains inserted (each `insert` of a
    /// previously-unseen domain counts once; re-inserting an existing
    /// domain is a no-op and does not double-count).
    public private(set) var count = 0

    public init() {}

    /// Inserts `domain` as a blocked/allowed entry (whichever this trie
    /// represents). Marks only the exact end node terminal -- everything
    /// *below* it is implicitly covered by `contains(host:)`'s walk, so
    /// subdomains never need their own entries.
    public func insert(_ domain: String) {
        var node = root
        for label in Self.labels(of: domain) {
            if let existing = node.children[label] {
                node = existing
            } else {
                let created = Node()
                node.children[label] = created
                node = created
            }
        }
        if !node.isTerminal {
            node.isTerminal = true
            count += 1
        }
    }

    /// True if `host` itself, or any ancestor domain of `host` (its
    /// parent, grandparent, ... up to the TLD), was inserted.
    public func contains(host: String) -> Bool {
        var node = root
        for label in Self.labels(of: host) {
            guard let next = node.children[label] else { return false }
            node = next
            if node.isTerminal { return true }
        }
        return false
    }

    /// Splits a domain into root-first labels (`ads.example.com` ->
    /// `["com", "example", "ads"]`), lowercased for case-insensitive
    /// matching (hostnames are ASCII/punycode case-insensitive) with a
    /// single trailing dot (some hosts-file entries end in one, e.g.
    /// `example.com.`) stripped first.
    private static func labels(of domain: String) -> [String] {
        var trimmed = Substring(domain.lowercased())
        if trimmed.hasSuffix(".") {
            trimmed = trimmed.dropLast()
        }
        return trimmed.split(separator: ".").reversed().map(String.init)
    }
}
