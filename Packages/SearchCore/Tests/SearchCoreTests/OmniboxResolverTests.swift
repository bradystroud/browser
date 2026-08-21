import Foundation
import Testing
@testable import SearchCore

private let sites = [
    QuickSiteSearchSite(
        keyword: "github", host: "github.com",
        template: "https://github.com/search?q={searchTerms}", useCount: 5
    )
]

private func resolve(_ input: String, engine: SearchEngine = .duckDuckGo, quickSites: [QuickSiteSearchSite] = []) -> String? {
    if case .navigate(let url) = OmniboxResolver.resolve(input: input, engine: engine, quickSites: quickSites) {
        return url
    }
    return nil
}

@Suite("Omnibox resolution")
struct OmniboxResolverTests {
    @Test("a URL navigates and never reaches the search engine")
    func urlWins() {
        #expect(resolve("example.com") == "https://example.com")
        #expect(resolve("example.com", quickSites: sites) == "https://example.com")
    }

    @Test("a search goes to the selected engine")
    func searchUsesSelectedEngine() {
        #expect(resolve("swift concurrency") == "https://duckduckgo.com/?q=swift%20concurrency")
        #expect(resolve("swift concurrency", engine: .google) == "https://www.google.com/search?q=swift%20concurrency")
        #expect(resolve("swift concurrency", engine: .kagi) == "https://kagi.com/search?q=swift%20concurrency")
    }

    @Test("a custom engine is used just like a built-in one")
    func customEngine() {
        let engine = SearchEngine.custom(template: "https://search.example/?query={searchTerms}")
        #expect(resolve("swift", engine: engine ?? .duckDuckGo) == "https://search.example/?query=swift")
    }

    @Test("empty input does nothing rather than navigating somewhere")
    func emptyInput() {
        #expect(OmniboxResolver.resolve(input: "   ", engine: .duckDuckGo) == .nothing)
    }

    @Test("a site keyword claims the input ahead of the search engine")
    func quickSiteSearchWins() {
        #expect(resolve("github concurrency", quickSites: sites) == "https://github.com/search?q=concurrency")
    }

    @Test("with no sites known, the same input is an ordinary search")
    func quickSiteSearchDisabled() {
        #expect(resolve("github concurrency") == "https://duckduckgo.com/?q=github%20concurrency")
    }

    @Test("a leading ? searches the engine even when a site keyword would match")
    func forcedSearchBeatsQuickSite() {
        #expect(resolve("?github concurrency", quickSites: sites) == "https://duckduckgo.com/?q=github%20concurrency")
    }

    @Test("a leading ? searches for text that would otherwise navigate")
    func forcedSearchBeatsURL() {
        #expect(resolve("?example.com") == "https://duckduckgo.com/?q=example.com")
    }
}
