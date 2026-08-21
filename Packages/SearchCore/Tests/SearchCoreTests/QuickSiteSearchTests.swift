import Foundation
import Testing
@testable import SearchCore

@Suite("Quick Website Search: learning a site from a visit")
struct QuickSiteSearchLearningTests {
    @Test("a site's search results page becomes a template")
    func learnsTemplate() {
        let site = QuickSiteSearch.site(fromVisitedURL: "https://en.wikipedia.org/w/index.php?search=swift")
        #expect(site?.keyword == "wikipedia")
        #expect(site?.host == "en.wikipedia.org")
        #expect(site?.template == "https://en.wikipedia.org/w/index.php?search={searchTerms}")
    }

    @Test("other query parameters are preserved, so the site still gets what it needs")
    func preservesOtherParameters() {
        let site = QuickSiteSearch.site(fromVisitedURL: "https://example.com/find?type=all&q=swift&sort=new")
        #expect(site?.template == "https://example.com/find?type=all&q={searchTerms}&sort=new")
    }

    @Test("the fragment is dropped -- it is where the user scrolled to, not part of the search")
    func dropsFragment() {
        let site = QuickSiteSearch.site(fromVisitedURL: "https://example.com/find?q=swift#results")
        #expect(site?.template == "https://example.com/find?q={searchTerms}")
    }

    @Test("a page with no search parameter teaches nothing")
    func ignoresOrdinaryPages() {
        #expect(QuickSiteSearch.site(fromVisitedURL: "https://example.com/about") == nil)
        #expect(QuickSiteSearch.site(fromVisitedURL: "https://example.com/?utm_source=news") == nil)
    }

    @Test("a one-character value is a stray parameter, not a search")
    func ignoresTinyValues() {
        #expect(QuickSiteSearch.site(fromVisitedURL: "https://example.com/?q=1") == nil)
    }

    @Test("only http(s) pages teach a template")
    func ignoresOtherSchemes() {
        #expect(QuickSiteSearch.site(fromVisitedURL: "file:///tmp/x.html?q=swift") == nil)
    }

    @Test("a query with characters that need encoding still yields a clean template")
    func templateStaysReadable() {
        let site = QuickSiteSearch.site(fromVisitedURL: "https://example.com/?q=a%20b%26c")
        #expect(site?.template == "https://example.com/?q={searchTerms}")
        // And the template is usable: substituting encodes the new query
        // once, not twice.
        #expect(SearchEngine.fill(template: site?.template ?? "", with: "x y") == "https://example.com/?q=x%20y")
    }
}

@Suite("Quick Website Search: keywords")
struct QuickSiteSearchKeywordTests {
    @Test("the keyword is the site's name, without www or the public suffix")
    func derivesKeyword() {
        #expect(QuickSiteSearch.keyword(forHost: "github.com") == "github")
        #expect(QuickSiteSearch.keyword(forHost: "www.github.com") == "github")
        #expect(QuickSiteSearch.keyword(forHost: "en.wikipedia.org") == "wikipedia")
    }

    @Test("a two-part public suffix is handled")
    func twoPartSuffix() {
        #expect(QuickSiteSearch.keyword(forHost: "www.amazon.co.uk") == "amazon")
        #expect(QuickSiteSearch.keyword(forHost: "abc.net.au") == "abc")
    }

    @Test("a host with no suffix at all is its own keyword")
    func singleLabelHost() {
        #expect(QuickSiteSearch.keyword(forHost: "localhost") == "localhost")
    }
}

@Suite("Quick Website Search: matching typed input")
struct QuickSiteSearchMatchTests {
    private let sites = [
        QuickSiteSearchSite(
            keyword: "wikipedia", host: "en.wikipedia.org",
            template: "https://en.wikipedia.org/w/index.php?search={searchTerms}", useCount: 3
        ),
        QuickSiteSearchSite(
            keyword: "github", host: "github.com",
            template: "https://github.com/search?q={searchTerms}", useCount: 9
        ),
        QuickSiteSearchSite(
            keyword: "wiktionary", host: "en.wiktionary.org",
            template: "https://en.wiktionary.org/w/index.php?search={searchTerms}", useCount: 1
        ),
    ]

    @Test("an exact keyword plus a query searches that site")
    func exactKeyword() {
        let match = QuickSiteSearch.match(input: "github concurrency", sites: sites)
        #expect(match?.site.keyword == "github")
        #expect(match?.query == "concurrency")
        #expect(match?.url == "https://github.com/search?q=concurrency")
    }

    @Test("the keyword is matched case-insensitively")
    func caseInsensitive() {
        #expect(QuickSiteSearch.match(input: "GitHub concurrency", sites: sites)?.site.keyword == "github")
    }

    @Test("everything after the first word is the query, spaces and all")
    func multiWordQuery() {
        #expect(QuickSiteSearch.match(input: "github swift async await", sites: sites)?.query == "swift async await")
    }

    @Test("a keyword on its own is left alone -- it is an ordinary search")
    func keywordAloneIsNotAMatch() {
        #expect(QuickSiteSearch.match(input: "github", sites: sites) == nil)
        #expect(QuickSiteSearch.match(input: "github   ", sites: sites) == nil)
    }

    @Test("an unknown first word is left alone")
    func unknownKeyword() {
        #expect(QuickSiteSearch.match(input: "hello world", sites: sites) == nil)
    }

    @Test("a prefix reaches the site, and the most-used one wins a tie")
    func prefixMatch() {
        #expect(QuickSiteSearch.match(input: "wiki foo", sites: sites)?.site.keyword == "wikipedia")
        #expect(QuickSiteSearch.match(input: "wikt foo", sites: sites)?.site.keyword == "wiktionary")
    }

    @Test("an exact match beats a more-used site that merely shares the prefix")
    func exactBeatsPrefix() {
        let sites = [
            QuickSiteSearchSite(keyword: "go", host: "go.dev", template: "https://go.dev/s?q={searchTerms}", useCount: 1),
            QuickSiteSearchSite(keyword: "google", host: "google.com", template: "https://google.com/s?q={searchTerms}", useCount: 50),
        ]
        #expect(QuickSiteSearch.match(input: "go routines", sites: sites)?.site.keyword == "go")
    }

    @Test("the query is percent-encoded into the template")
    func encodesQuery() {
        #expect(QuickSiteSearch.match(input: "github a&b", sites: sites)?.url == "https://github.com/search?q=a%26b")
    }

    @Test("no sites means no matches")
    func emptyStore() {
        #expect(QuickSiteSearch.match(input: "github x", sites: []) == nil)
    }
}
