import Foundation
import Testing
@testable import SearchCore

private func parse(_ json: String, query: String = "sw", limit: Int = 5) -> [String] {
    SearchSuggestionParser.parse(Data(json.utf8), query: query, limit: limit)
}

@Suite("Search suggestion parsing")
struct SearchSuggestionParserTests {
    @Test("the OpenSearch array form is read")
    func openSearchForm() {
        #expect(parse(#"["sw", ["swift", "swift ui", "sweden"]]"#) == ["swift", "swift ui", "sweden"])
    }

    @Test("DuckDuckGo's object form is read as well")
    func objectForm() {
        #expect(parse(#"[{"phrase": "swift"}, {"phrase": "sweden"}]"#) == ["swift", "sweden"])
    }

    @Test("a suggestion identical to what was typed is dropped -- the omnibox already offers it")
    func dropsEchoOfQuery() {
        #expect(parse(#"["sw", ["sw", "SW", "swift"]]"#) == ["swift"])
    }

    @Test("duplicates are removed case-insensitively, keeping the engine's ranking")
    func deduplicates() {
        #expect(parse(#"["sw", ["Swift", "swift", "sweden"]]"#) == ["Swift", "sweden"])
    }

    @Test("blank entries are dropped")
    func dropsBlanks() {
        #expect(parse(#"["sw", ["", "   ", "swift"]]"#) == ["swift"])
    }

    @Test("the limit is respected")
    func respectsLimit() {
        #expect(parse(#"["sw", ["a", "b", "c", "d"]]"#, limit: 2) == ["a", "b"])
    }

    @Test("malformed or unexpected payloads yield nothing rather than throwing")
    func malformedPayloads() {
        #expect(parse("not json").isEmpty)
        #expect(parse("").isEmpty)
        #expect(parse(#"{"suggestions": ["swift"]}"#).isEmpty)
        #expect(parse(#"["sw"]"#).isEmpty)
        #expect(parse(#"["sw", "swift"]"#).isEmpty)
        #expect(parse(#"["sw", [1, 2, 3]]"#).isEmpty)
    }
}
