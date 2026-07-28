import Foundation
import Testing
@testable import BlockListCore

@Suite("BlockingSettings + BlockList combination")
struct BlockingSettingsTests {
    @Test("a blocked host is blocked when enabled and not allowlisted")
    func blockedHostIsBlocked() {
        let blockList = BlockList()
        blockList.addDomain("ads.example.com")
        let settings = BlockingSettings()

        #expect(settings.shouldBlock(host: "ads.example.com", blockList: blockList))
    }

    @Test("disabling settings blocks nothing, regardless of list contents")
    func disabledNeverBlocks() {
        let blockList = BlockList()
        blockList.addDomain("ads.example.com")
        let settings = BlockingSettings(isEnabled: false)

        #expect(!settings.shouldBlock(host: "ads.example.com", blockList: blockList))
    }

    @Test("an allowlisted host is never blocked, even if it's in the block list -- allowlist always wins")
    func allowlistTakesPrecedence() {
        let blockList = BlockList()
        blockList.addDomain("example.com")
        let settings = BlockingSettings(allowlistedHosts: ["example.com"])

        #expect(!settings.shouldBlock(host: "example.com", blockList: blockList))
    }

    @Test("allowlisting a domain also un-blocks its subdomains (subdomain-inclusive, like DomainTrie)")
    func allowlistIsSubdomainInclusive() {
        let blockList = BlockList()
        blockList.addDomain("ads.example.com")
        let settings = BlockingSettings(allowlistedHosts: ["example.com"])

        #expect(!settings.shouldBlock(host: "ads.example.com", blockList: blockList))
    }

    @Test("allowlisting one domain doesn't affect an unrelated blocked domain")
    func allowlistDoesNotLeakToOtherDomains() {
        let blockList = BlockList()
        blockList.addDomain("example.com")
        blockList.addDomain("other-blocked.com")
        let settings = BlockingSettings(allowlistedHosts: ["example.com"])

        #expect(!settings.shouldBlock(host: "example.com", blockList: blockList))
        #expect(settings.shouldBlock(host: "other-blocked.com", blockList: blockList))
    }

    @Test("shouldBlock(url:) extracts the host and fails open on an unparseable URL")
    func urlConvenienceOverload() {
        let blockList = BlockList()
        blockList.addDomain("ads.example.com")
        let settings = BlockingSettings()

        #expect(settings.shouldBlock(url: "https://ads.example.com/pixel.gif", blockList: blockList))
        #expect(!settings.shouldBlock(url: "not a url at all", blockList: blockList))
    }

    @Test("BlockingSettings round-trips through Codable")
    func codableRoundTrip() throws {
        let settings = BlockingSettings(isEnabled: false, allowlistedHosts: ["example.com", "other.org"])
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BlockingSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("the bundled starter list loads without error and covers a well-known tracker domain")
    func starterListLoads() {
        let blockList = BlockList()
        let added = blockList.loadStarterList()

        #expect(added > 50)
        #expect(blockList.contains(host: "doubleclick.net"))
        #expect(blockList.contains(host: "stats.doubleclick.net"))
        #expect(!blockList.contains(host: "example.com"))
    }
}
