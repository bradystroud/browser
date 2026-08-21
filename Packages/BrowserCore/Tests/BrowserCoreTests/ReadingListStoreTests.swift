import XCTest
@testable import BrowserCore

final class ReadingListStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ReadingListStore!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        store = ReadingListStore(database: try Database(profileDirectory: dir))
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    // MARK: - Adding

    func testAddedItemStartsUnreadAndWithoutAnOfflineCopy() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")

        let item = try XCTUnwrap(store.item(url: "https://example.com/a"))
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.title, "A")
        XCTAssertFalse(item.isRead)
        XCTAssertNil(item.readAt)
        // Capture happens later and can fail: "saved but not yet captured"
        // is a normal state, not a broken one.
        XCTAssertFalse(item.hasArticle)
        XCTAssertNil(try store.article(id: id))
    }

    func testItemsAreNewestFirst() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try store.add(url: "https://example.com/old", title: "Old", at: base)
        _ = try store.add(url: "https://example.com/new", title: "New", at: base.addingTimeInterval(60))

        XCTAssertEqual(try store.items().map(\.title), ["New", "Old"])
    }

    func testReAddingAnUnreadItemDoesNotDuplicateItOrMoveIt() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.add(url: "https://example.com/a", title: "A", at: base)
        _ = try store.add(url: "https://example.com/b", title: "B", at: base.addingTimeInterval(60))
        let again = try store.add(url: "https://example.com/a", title: "A", at: base.addingTimeInterval(120))

        XCTAssertEqual(again, first)
        // Still second: an unread item's place in the list is where the user
        // put it, and re-adding it says nothing new.
        XCTAssertEqual(try store.items().map(\.title), ["B", "A"])
    }

    func testReAddingRefreshesAStaleTitleButNeverBlanksIt() throws {
        let id = try store.add(url: "https://example.com/a", title: "Untitled")
        _ = try store.add(url: "https://example.com/a", title: "The Real Title")
        XCTAssertEqual(try store.item(url: "https://example.com/a")?.title, "The Real Title")

        // A page added before its <title> resolved would otherwise wipe the
        // good title stored a moment ago.
        _ = try store.add(url: "https://example.com/a", title: "")
        XCTAssertEqual(try store.item(url: "https://example.com/a")?.title, "The Real Title")
        XCTAssertEqual(try store.items().map(\.id), [id])
    }

    func testReAddingAReadItemMarksItUnreadAndMovesItToTheTop() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try store.add(url: "https://example.com/a", title: "A", at: base)
        _ = try store.add(url: "https://example.com/b", title: "B", at: base.addingTimeInterval(60))
        try store.markRead(id: a)

        _ = try store.add(url: "https://example.com/a", title: "A", at: base.addingTimeInterval(120))

        let items = try store.items()
        XCTAssertEqual(items.map(\.title), ["A", "B"])
        XCTAssertFalse(try XCTUnwrap(store.item(url: "https://example.com/a")).isRead)
        XCTAssertNil(try XCTUnwrap(store.item(url: "https://example.com/a")).readAt)
    }

    func testContainsAnswersForBothStates() throws {
        _ = try store.add(url: "https://example.com/a", title: "A")
        XCTAssertTrue(try store.contains(url: "https://example.com/a"))
        XCTAssertFalse(try store.contains(url: "https://example.com/other"))
    }

    // MARK: - Offline capture

    func testSavedArticleComesBackExactlyAsStored() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        // Markup, entities and quotes all have to survive a round trip
        // untouched -- this string is inserted into a document as-is.
        let html = "<p>Sant &amp; Co\u{2019}s \"best\" &lt;year&gt;</p><img src=\"x.png\">"
        try store.saveArticle(id: id, content: html, byline: "By Marcia Perez", excerpt: "A summary.")

        XCTAssertEqual(try store.article(id: id), html)
        let item = try XCTUnwrap(store.item(url: "https://example.com/a"))
        XCTAssertTrue(item.hasArticle)
        XCTAssertEqual(item.byline, "By Marcia Perez")
        XCTAssertEqual(item.excerpt, "A summary.")
    }

    func testEmptyArticleStillCountsAsCaptured() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        try store.saveArticle(id: id, content: "")
        // An article that genuinely extracted to nothing is a captured
        // result, not a missing one -- retrying it forever would be worse.
        XCTAssertTrue(try XCTUnwrap(store.item(url: "https://example.com/a")).hasArticle)
        XCTAssertEqual(try store.article(id: id), "")
    }

    func testAnOversizedArticleIsRefusedAndLeavesTheItemUncaptured() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        let tooBig = String(repeating: "x", count: ReadingListStore.maximumArticleBytes + 1)

        XCTAssertThrowsError(try store.saveArticle(id: id, content: tooBig)) { error in
            XCTAssertEqual(error as? ReadingListError, .articleTooLarge)
        }
        XCTAssertFalse(try XCTUnwrap(store.item(url: "https://example.com/a")).hasArticle)
    }

    func testTheSizeLimitCountsBytesNotCharacters() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        // Each of these is 4 UTF-8 bytes, so a string well under the limit
        // in characters is well over it in bytes.
        let emoji = String(repeating: "\u{1F600}", count: ReadingListStore.maximumArticleBytes / 2)
        XCTAssertThrowsError(try store.saveArticle(id: id, content: emoji))
    }

    func testSavingAnArticleForAnUnknownItemFails() throws {
        XCTAssertThrowsError(try store.saveArticle(id: 999, content: "<p>x</p>")) { error in
            XCTAssertEqual(error as? ReadingListError, .itemNotFound)
        }
    }

    func testRecapturingReplacesTheStoredArticle() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        try store.saveArticle(id: id, content: "<p>first</p>", byline: "First")
        try store.saveArticle(id: id, content: "<p>second</p>", byline: "Second")

        XCTAssertEqual(try store.article(id: id), "<p>second</p>")
        XCTAssertEqual(try store.item(url: "https://example.com/a")?.byline, "Second")
    }

    // MARK: - Read state

    func testMarkingReadAndUnread() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)

        try store.markRead(id: id, at: readAt)
        var item = try XCTUnwrap(store.item(url: "https://example.com/a"))
        XCTAssertTrue(item.isRead)
        XCTAssertEqual(item.readAt?.timeIntervalSince1970 ?? 0, readAt.timeIntervalSince1970, accuracy: 0.001)

        try store.markRead(id: id, false)
        item = try XCTUnwrap(store.item(url: "https://example.com/a"))
        XCTAssertFalse(item.isRead)
        // Cleared, not left pointing at a read that has been undone.
        XCTAssertNil(item.readAt)
    }

    func testUnreadOnlyFiltersAndUnreadCountAgrees() throws {
        let a = try store.add(url: "https://example.com/a", title: "A")
        _ = try store.add(url: "https://example.com/b", title: "B")
        _ = try store.add(url: "https://example.com/c", title: "C")
        try store.markRead(id: a)

        XCTAssertEqual(try store.items(unreadOnly: true).map(\.title), ["C", "B"])
        XCTAssertEqual(try store.items().count, 3)
        XCTAssertEqual(try store.unreadCount(), 2)
    }

    func testMarkingAnUnknownItemReadFails() throws {
        XCTAssertThrowsError(try store.markRead(id: 999)) { error in
            XCTAssertEqual(error as? ReadingListError, .itemNotFound)
        }
    }

    // MARK: - Removing

    func testRemoveTakesTheArticleWithIt() throws {
        let id = try store.add(url: "https://example.com/a", title: "A")
        try store.saveArticle(id: id, content: "<p>x</p>")

        try store.remove(id: id)
        XCTAssertNil(try store.item(url: "https://example.com/a"))
        XCTAssertNil(try store.article(id: id))
    }

    func testRemovingAnUnknownItemFails() throws {
        XCTAssertThrowsError(try store.remove(id: 999)) { error in
            XCTAssertEqual(error as? ReadingListError, .itemNotFound)
        }
    }

    func testRemoveReadKeepsTheUnreadOnes() throws {
        let a = try store.add(url: "https://example.com/a", title: "A")
        let b = try store.add(url: "https://example.com/b", title: "B")
        _ = try store.add(url: "https://example.com/c", title: "C")
        try store.markRead(id: a)
        try store.markRead(id: b)

        XCTAssertEqual(try store.removeRead(), 2)
        XCTAssertEqual(try store.items().map(\.title), ["C"])
        XCTAssertEqual(try store.removeRead(), 0)
    }

    func testRemoveAllEmptiesTheList() throws {
        _ = try store.add(url: "https://example.com/a", title: "A")
        _ = try store.add(url: "https://example.com/b", title: "B")

        try store.removeAll()
        XCTAssertTrue(try store.items().isEmpty)
        XCTAssertEqual(try store.unreadCount(), 0)
    }

    // MARK: - Notifications

    func testEveryMutationPostsDidChange() throws {
        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: .readingListDidChange, object: store, queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let id = try store.add(url: "https://example.com/a", title: "A")
        try store.saveArticle(id: id, content: "<p>x</p>")
        try store.markRead(id: id)
        try store.remove(id: id)

        XCTAssertEqual(posted, 4)
    }

    func testAFailedMutationPostsNothing() throws {
        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: .readingListDidChange, object: store, queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertThrowsError(try store.markRead(id: 999))
        XCTAssertThrowsError(try store.remove(id: 999))
        XCTAssertEqual(posted, 0)
    }
}
