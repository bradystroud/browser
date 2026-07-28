import Testing
@testable import BlockListCore

@Suite("ListParser line classification")
struct ListParserLineTests {
    @Test("hosts-file format: single hostname after a redirect address")
    func hostsFileSingleHostname() {
        #expect(ListParser.domains(inLine: "0.0.0.0 ads.example.com") == ["ads.example.com"])
        #expect(ListParser.domains(inLine: "127.0.0.1 ads.example.com") == ["ads.example.com"])
    }

    @Test("hosts-file format: multiple hostnames after the same address")
    func hostsFileMultipleHostnames() {
        #expect(ListParser.domains(inLine: "0.0.0.0 a.example.com b.example.com") == ["a.example.com", "b.example.com"])
    }

    @Test("plain domain-per-line format: a bare domain with no address prefix")
    func plainDomainFormat() {
        #expect(ListParser.domains(inLine: "ads.example.com") == ["ads.example.com"])
    }

    @Test("inline comments are stripped, trailing/leading whitespace is trimmed")
    func inlineCommentsStripped() {
        #expect(ListParser.domains(inLine: "0.0.0.0 ads.example.com # tracker") == ["ads.example.com"])
        #expect(ListParser.domains(inLine: "  ads.example.com  ") == ["ads.example.com"])
    }

    @Test("a full-line comment produces no domains")
    func fullLineComment() {
        #expect(ListParser.domains(inLine: "# this is a header comment") == [])
        #expect(ListParser.domains(inLine: "#no space after hash either") == [])
    }

    @Test("blank and whitespace-only lines produce no domains")
    func blankLines() {
        #expect(ListParser.domains(inLine: "") == [])
        #expect(ListParser.domains(inLine: "   ") == [])
        #expect(ListParser.domains(inLine: "\t") == [])
    }

    @Test("standard hosts-file loopback boilerplate is skipped, not treated as a blocked domain")
    func loopbackBoilerplateSkipped() {
        #expect(ListParser.domains(inLine: "127.0.0.1 localhost") == [])
        #expect(ListParser.domains(inLine: "255.255.255.255 broadcasthost") == [])
        #expect(ListParser.domains(inLine: "::1 localhost") == [])
        #expect(ListParser.domains(inLine: "127.0.0.1 localhost.localdomain") == [])
    }

    @Test("a line mapping a real routable IP to a hostname is not a blocklist entry")
    func realRoutableIPIsNotABlocklistLine() {
        #expect(ListParser.domains(inLine: "192.168.1.1 myrouter.local") == [])
        #expect(ListParser.domains(inLine: "10.0.0.5 internal-service") == [])
    }

    @Test("domains are lowercased")
    func lowercased() {
        #expect(ListParser.domains(inLine: "0.0.0.0 ADS.EXAMPLE.COM") == ["ads.example.com"])
    }

    @Test("tab-separated hosts-file lines are handled the same as space-separated")
    func tabSeparated() {
        #expect(ListParser.domains(inLine: "0.0.0.0\tads.example.com") == ["ads.example.com"])
    }
}

@Suite("ListParser full-text parsing")
struct ListParserFullTextTests {
    @Test("a mixed hosts-file + plain-domain text loads every recognized domain, skipping boilerplate/comments")
    func mixedFormatText() {
        let text = """
        # Standard hosts-file boilerplate
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        ::1 localhost

        # Ad/tracker entries (hosts-file style)
        0.0.0.0 ads.example.com
        0.0.0.0 a.tracker.net b.tracker.net

        # Plain domain-per-line entries
        another-tracker.com
        yet-another.example
        """

        let trie = DomainTrie()
        let added = ListParser.parse(text, into: trie)

        #expect(added == 5)
        #expect(trie.contains(host: "ads.example.com"))
        #expect(trie.contains(host: "a.tracker.net"))
        #expect(trie.contains(host: "b.tracker.net"))
        #expect(trie.contains(host: "another-tracker.com"))
        #expect(trie.contains(host: "yet-another.example"))
        #expect(!trie.contains(host: "localhost"))
        #expect(!trie.contains(host: "broadcasthost"))
    }

    @Test("re-parsing the same text twice does not double the count")
    func idempotentParsing() {
        let text = "one.example\ntwo.example\n"
        let trie = DomainTrie()
        let firstPass = ListParser.parse(text, into: trie)
        let secondPass = ListParser.parse(text, into: trie)

        #expect(firstPass == 2)
        #expect(secondPass == 0)
        #expect(trie.count == 2)
    }
}
