import Foundation
import Testing
@testable import SearchCore

@Suite("Search engine templates")
struct SearchEngineTemplateTests {
    @Test("every built-in engine produces a search URL and a suggestion URL")
    func builtInsAreComplete() {
        for engine in SearchEngine.builtIns {
            #expect(engine.searchURL(for: "swift") != nil)
            #expect(engine.suggestURL(for: "swift") != nil)
        }
    }

    @Test("the default engine is DuckDuckGo, matching what the omnibox did before the setting existed")
    func defaultEngine() {
        #expect(SearchEngine.default.choice == .duckDuckGo)
        #expect(SearchEngine.default.searchURL(for: "swift") == "https://duckduckgo.com/?q=swift")
    }

    @Test("a choice round-trips through its raw value, because that is what gets persisted")
    func choiceRawValues() {
        for choice in SearchEngineChoice.allCases {
            #expect(SearchEngineChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(SearchEngineChoice.duckDuckGo.rawValue == "duckduckgo")
    }

    @Test("builtIn(_:) answers for the four built-ins and not for custom")
    func builtInLookup() {
        #expect(SearchEngine.builtIn(.google)?.name == "Google")
        #expect(SearchEngine.builtIn(.kagi)?.name == "Kagi")
        #expect(SearchEngine.builtIn(.custom) == nil)
    }
}

@Suite("Query encoding")
struct QueryEncodingTests {
    @Test("a space becomes %20, not a raw space")
    func encodesSpaces() {
        #expect(SearchEngine.google.searchURL(for: "hello world")
            == "https://www.google.com/search?q=hello%20world")
    }

    @Test("characters that would rewrite the template's own parameters are encoded")
    func encodesDelimiters() {
        let url = SearchEngine.duckDuckGo.searchURL(for: "a&b=c#d+e")
        #expect(url == "https://duckduckgo.com/?q=a%26b%3Dc%23d%2Be")
    }

    @Test("unicode is percent-encoded as UTF-8")
    func encodesUnicode() {
        #expect(SearchEngine.duckDuckGo.searchURL(for: "café") == "https://duckduckgo.com/?q=caf%C3%A9")
    }

    @Test("a query is never allowed to escape into the path")
    func encodesSlashes() {
        #expect(SearchEngine.duckDuckGo.searchURL(for: "a/b") == "https://duckduckgo.com/?q=a%2Fb")
    }

    @Test("a template with no placeholder produces nothing rather than a query-less search")
    func templateWithoutPlaceholder() {
        #expect(SearchEngine.fill(template: "https://example.com/search", with: "x") == nil)
    }
}

@Suite("Custom search engines")
struct CustomEngineTests {
    @Test("a {searchTerms} template is accepted and names itself after its host")
    func acceptsOpenSearchTemplate() {
        let engine = SearchEngine.custom(template: "https://search.marcia.example/?query={searchTerms}")
        #expect(engine?.name == "search.marcia.example")
        #expect(engine?.searchURL(for: "a b") == "https://search.marcia.example/?query=a%20b")
    }

    @Test("Chrome's %s placeholder is accepted too, since that is what people have to hand")
    func acceptsPercentS() {
        let engine = SearchEngine.custom(template: "https://example.com/s?q=%s")
        #expect(engine?.searchURL(for: "swift") == "https://example.com/s?q=swift")
    }

    @Test("a leading www. is dropped from the derived name")
    func dropsWWWFromName() {
        #expect(SearchEngine.custom(template: "https://www.example.com/?q={searchTerms}")?.name == "example.com")
    }

    @Test("a template with no placeholder is rejected")
    func rejectsMissingPlaceholder() {
        #expect(SearchEngine.custom(template: "https://example.com/search?q=") == nil)
        #expect(!SearchEngine.isValidTemplate("https://example.com/search?q="))
    }

    @Test("a non-http(s) template is rejected -- a template is followed on every single search")
    func rejectsDangerousSchemes() {
        #expect(SearchEngine.custom(template: "javascript:alert({searchTerms})") == nil)
        #expect(SearchEngine.custom(template: "file:///tmp/{searchTerms}") == nil)
        #expect(SearchEngine.custom(template: "data:text/html,{searchTerms}") == nil)
    }

    @Test("a template that is not a URL at all is rejected")
    func rejectsNonURL() {
        #expect(SearchEngine.custom(template: "{searchTerms}") == nil)
        #expect(SearchEngine.custom(template: "") == nil)
        #expect(SearchEngine.custom(template: "   ") == nil)
    }

    @Test("surrounding whitespace is trimmed rather than making the template invalid")
    func trimsTemplate() {
        #expect(SearchEngine.custom(template: "  https://example.com/?q={searchTerms}  ")?.searchTemplate
            == "https://example.com/?q={searchTerms}")
    }

    @Test("a custom engine offers no suggestions -- there is no way to discover its endpoint")
    func customHasNoSuggestions() {
        #expect(SearchEngine.custom(template: "https://example.com/?q={searchTerms}")?.suggestURL(for: "x") == nil)
    }
}
