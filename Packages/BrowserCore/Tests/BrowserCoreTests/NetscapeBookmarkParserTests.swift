import XCTest
@testable import BrowserCore

final class NetscapeBookmarkParserTests: XCTestCase {
    /// A realistic Safari export: sloppy in exactly the ways real Safari
    /// output is sloppy -- no closing `</DT>` anywhere, a stray `<p>` after
    /// every `<DL>`, and a `PERSONAL_TOOLBAR_FOLDER="true"` marker on the
    /// "Favorites" folder. Nested two levels deep, matching the ask for "a
    /// Safari-shaped export with nested folders and a Favorites bar
    /// folder."
    private static let safariShapedFixture = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 FOLDED ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Favorites</H3>
        <DL><p>
            <DT><A HREF="https://apple.com" ADD_DATE="1700000001">Apple</A>
            <DT><A HREF="https://swift.org" ADD_DATE="1700000002">Swift.org</A>
        </DL><p>
        <DT><H3 ADD_DATE="1700000003">Work</H3>
        <DL><p>
            <DT><A HREF="https://github.com" ADD_DATE="1700000004">GitHub</A>
            <DT><H3 ADD_DATE="1700000005">Nested Project</H3>
            <DL><p>
                <DT><A HREF="https://nested.example" ADD_DATE="1700000006">Nested Link</A>
            </DL><p>
        </DL><p>
        <DT><A HREF="https://toplevel.example" ADD_DATE="1700000007">Top-level bookmark</A>
    </DL><p>
    """

    func testSafariShapedFixtureParsesFullTreeStructure() {
        let nodes = NetscapeBookmarkParser.parse(Self.safariShapedFixture)

        // Top level: Favorites folder, Work folder, one bare bookmark.
        XCTAssertEqual(nodes.count, 3)

        guard case .folder(let favTitle, let favIsBar, let favChildren) = nodes[0] else {
            return XCTFail("expected first top-level node to be a folder")
        }
        XCTAssertEqual(favTitle, "Favorites")
        XCTAssertTrue(favIsBar, "PERSONAL_TOOLBAR_FOLDER=\"true\" should mark this as the favorites-bar folder")
        XCTAssertEqual(favChildren, [
            .bookmark(title: "Apple", url: "https://apple.com"),
            .bookmark(title: "Swift.org", url: "https://swift.org"),
        ])

        guard case .folder(let workTitle, let workIsBar, let workChildren) = nodes[1] else {
            return XCTFail("expected second top-level node to be a folder")
        }
        XCTAssertEqual(workTitle, "Work")
        XCTAssertFalse(workIsBar)
        XCTAssertEqual(workChildren.count, 2)
        XCTAssertEqual(workChildren[0], .bookmark(title: "GitHub", url: "https://github.com"))
        guard case .folder(let nestedTitle, _, let nestedChildren) = workChildren[1] else {
            return XCTFail("expected Work's second child to be the Nested Project folder")
        }
        XCTAssertEqual(nestedTitle, "Nested Project")
        XCTAssertEqual(nestedChildren, [.bookmark(title: "Nested Link", url: "https://nested.example")])

        XCTAssertEqual(nodes[2], .bookmark(title: "Top-level bookmark", url: "https://toplevel.example"))
    }

    func testChromeStyleFavoritesBarTitleWithoutMarkerAttribute() {
        // Chrome's export sometimes omits PERSONAL_TOOLBAR_FOLDER but the
        // folder's title itself ("Bookmarks bar") is still recognizable.
        let html = """
        <DL><p>
            <DT><H3 ADD_DATE="1">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://chrome.example">Chrome Site</A>
            </DL><p>
        </DL><p>
        """
        let nodes = NetscapeBookmarkParser.parse(html)
        guard case .folder(_, let isBar, _) = nodes.first else {
            return XCTFail("expected a folder")
        }
        XCTAssertTrue(isBar)
    }

    func testMissingClosingDLIsTolerated() {
        // A truncated/very sloppily-closed export -- the outer </DL> is
        // simply absent. Nothing should be dropped or throw.
        let html = """
        <DL><p>
            <DT><H3>Folder</H3>
            <DL><p>
                <DT><A HREF="https://example.com">Example</A>
        """
        let nodes = NetscapeBookmarkParser.parse(html)
        XCTAssertEqual(nodes.count, 1)
        guard case .folder(let title, _, let children) = nodes[0] else {
            return XCTFail("expected a folder despite the missing closing tags")
        }
        XCTAssertEqual(title, "Folder")
        XCTAssertEqual(children, [.bookmark(title: "Example", url: "https://example.com")])
    }

    func testHTMLEntitiesInTitlesAndURLsAreUnescaped() {
        let html = """
        <DL><p>
            <DT><A HREF="https://example.com/?a=1&amp;b=2">Tom &amp; Jerry&#39;s &quot;Site&quot;</A>
        </DL><p>
        """
        let nodes = NetscapeBookmarkParser.parse(html)
        XCTAssertEqual(nodes, [.bookmark(title: "Tom & Jerry's \"Site\"", url: "https://example.com/?a=1&b=2")])
    }

    func testEmptyDocumentProducesNoNodes() {
        XCTAssertEqual(NetscapeBookmarkParser.parse(""), [])
        XCTAssertEqual(NetscapeBookmarkParser.parse("<DL><p></DL><p>"), [])
    }

    func testCountsAcrossNestedFolders() {
        let nodes = NetscapeBookmarkParser.parse(Self.safariShapedFixture)
        let counts = ImportedBookmarkNode.counts(in: nodes)
        // Favorites (2) + Work/GitHub (1) + Nested Project/Nested Link (1) + top-level bookmark (1) = 5
        XCTAssertEqual(counts.bookmarks, 5)
        // Favorites, Work, Nested Project = 3
        XCTAssertEqual(counts.folders, 3)
    }

    func testBareLeafWithNoHREFIsSkippedNotCrashed() {
        let html = """
        <DT><A>No href here</A>
        <DT><A HREF="https://real.example">Real</A>
        """
        let nodes = NetscapeBookmarkParser.parse(html)
        XCTAssertEqual(nodes, [.bookmark(title: "Real", url: "https://real.example")])
    }
}
