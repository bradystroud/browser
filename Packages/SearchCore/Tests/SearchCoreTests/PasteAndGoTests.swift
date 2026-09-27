import Foundation
import Testing
@testable import SearchCore

@Suite("Paste and Go")
struct PasteAndGoTests {
    @Test("a URL goes, words search")
    func actions() {
        #expect(PasteAndGo.action(for: "https://example.com/a") == .go)
        #expect(PasteAndGo.action(for: "example.com") == .go)
        #expect(PasteAndGo.action(for: "how tall is everest") == .search)
        #expect(PasteAndGo.menuTitle(for: "example.com") == "Paste and Go")
        #expect(PasteAndGo.menuTitle(for: "hello world") == "Paste and Search")
    }

    @Test("an empty or whitespace clipboard has nothing to do")
    func empty() {
        #expect(PasteAndGo.action(for: nil) == nil)
        #expect(PasteAndGo.action(for: "  \n\t ") == nil)
        #expect(PasteAndGo.normalize("\n\n") == nil)
        #expect(PasteAndGo.menuTitle(for: nil) == "Paste and Go")
    }

    @Test("surrounding whitespace is dropped")
    func trimmed() {
        #expect(PasteAndGo.normalize("  https://example.com  \n") == "https://example.com")
    }

    @Test("a URL wrapped across lines is rejoined without spaces")
    func wrappedURL() {
        #expect(PasteAndGo.normalize("https://example.com/some/very/\nlong/path?q=1") == "https://example.com/some/very/long/path?q=1")
        #expect(PasteAndGo.action(for: "https://example.com/a\r\nb") == .go)
    }

    @Test("several lines of prose become one search")
    func prose() {
        #expect(PasteAndGo.normalize("first line\nsecond line") == "first line second line")
        #expect(PasteAndGo.action(for: "first line\nsecond line") == .search)
    }
}
