import Testing
@testable import BlockListCore

@Suite("BlockList domain enumeration")
struct BlockListEnumerationTests {
    @Test("allDomains reflects every domain added via addDomain or load, with no duplicates")
    func allDomainsReflectsContents() {
        let blockList = BlockList()
        blockList.addDomain("example.com")
        blockList.load("tracker.net\nother.example\ntracker.net\n")

        let all = Set(blockList.allDomains())
        #expect(all == ["example.com", "tracker.net", "other.example"])
        #expect(blockList.domainCount == 3)
    }

    @Test("ListParser.parseDomains returns every recognized domain in file order, including duplicates")
    func parseDomainsReturnsRawList() {
        let text = "one.example\n0.0.0.0 two.example\none.example\n"
        #expect(ListParser.parseDomains(text) == ["one.example", "two.example", "one.example"])
    }

    @Test("a freshly constructed BlockList has no domains")
    func emptyByDefault() {
        let blockList = BlockList()
        #expect(blockList.allDomains().isEmpty)
        #expect(blockList.domainCount == 0)
    }
}
