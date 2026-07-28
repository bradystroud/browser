import Testing
@testable import BlockListCore

@Suite("DomainTrie subdomain semantics")
struct DomainTrieSubdomainTests {
    @Test("a blocked domain also blocks every subdomain of it")
    func blockedDomainCoversSubdomains() {
        let trie = DomainTrie()
        trie.insert("example.com")

        #expect(trie.contains(host: "example.com"))
        #expect(trie.contains(host: "ads.example.com"))
        #expect(trie.contains(host: "a.b.ads.example.com"))
    }

    @Test("a blocked domain does not block its own parent domain")
    func blockedDomainDoesNotCoverParent() {
        let trie = DomainTrie()
        trie.insert("ads.example.com")

        #expect(trie.contains(host: "ads.example.com"))
        #expect(!trie.contains(host: "example.com"))
        #expect(!trie.contains(host: "com"))
    }

    @Test("unrelated hosts are never blocked")
    func unrelatedHostNotBlocked() {
        let trie = DomainTrie()
        trie.insert("example.com")
        #expect(!trie.contains(host: "notexample.com"))
        #expect(!trie.contains(host: "example.com.evil.com"))
        #expect(!trie.contains(host: "other.org"))
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        let trie = DomainTrie()
        trie.insert("Example.COM")
        #expect(trie.contains(host: "EXAMPLE.com"))
        #expect(trie.contains(host: "ads.Example.Com"))
    }

    @Test("a trailing dot on either the stored domain or the queried host is tolerated")
    func trailingDotTolerated() {
        let trie = DomainTrie()
        trie.insert("example.com.")
        #expect(trie.contains(host: "example.com"))
        #expect(trie.contains(host: "example.com."))
    }

    @Test("count tracks distinct domains and does not double-count a re-insert")
    func countTracksDistinctDomains() {
        let trie = DomainTrie()
        #expect(trie.count == 0)
        trie.insert("example.com")
        #expect(trie.count == 1)
        trie.insert("example.com")
        #expect(trie.count == 1)
        trie.insert("other.com")
        #expect(trie.count == 2)
    }

    @Test("a multi-label ancestor only blocks itself and deeper, not intermediate parents")
    func multiLabelAncestor() {
        let trie = DomainTrie()
        trie.insert("a.b.c.com")

        #expect(trie.contains(host: "a.b.c.com"))
        #expect(trie.contains(host: "x.a.b.c.com"))
        #expect(!trie.contains(host: "b.c.com"))
        #expect(!trie.contains(host: "c.com"))
    }
}
