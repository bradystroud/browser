import XCTest
@testable import BrowserCore

final class BookmarkStoreTests: XCTestCase {
    private var dir: URL!
    private var store: BookmarkStore!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        store = BookmarkStore(database: try Database(profileDirectory: dir))
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testTopLevelItemsAppendInInsertionOrder() throws {
        let a = try store.addBookmark(title: "A", url: "https://a.example", parentId: nil)
        let b = try store.addFolder(title: "Folder B", parentId: nil)
        let c = try store.addBookmark(title: "C", url: "https://c.example", parentId: nil)

        let children = try store.children(of: nil)
        XCTAssertEqual(children.map(\.id), [a, b, c])
        XCTAssertEqual(children.map(\.position), [0, 1, 2])
    }

    func testFolderChildrenAreOrderedIndependentlyOfSiblingFolders() throws {
        let folder = try store.addFolder(title: "Work", parentId: nil)
        _ = try store.addBookmark(title: "Other top-level", url: "https://x.example", parentId: nil)

        let f1 = try store.addBookmark(title: "First", url: "https://1.example", parentId: folder)
        let f2 = try store.addBookmark(title: "Second", url: "https://2.example", parentId: folder)

        let children = try store.children(of: folder)
        XCTAssertEqual(children.map(\.id), [f1, f2])
        XCTAssertEqual(children.map(\.title), ["First", "Second"])
    }

    func testMoveWithinSameParentReordersSiblings() throws {
        let a = try store.addBookmark(title: "A", url: "https://a.example", parentId: nil)
        let b = try store.addBookmark(title: "B", url: "https://b.example", parentId: nil)
        let c = try store.addBookmark(title: "C", url: "https://c.example", parentId: nil)

        // Move C to the front: expect order C, A, B.
        try store.move(itemId: c, toParentId: nil, index: 0)

        let children = try store.children(of: nil)
        XCTAssertEqual(children.map(\.id), [c, a, b])
        XCTAssertEqual(children.map(\.position), [0, 1, 2])
    }

    func testMoveToDifferentFolderRenumbersBothParents() throws {
        let folderA = try store.addFolder(title: "A", parentId: nil)
        let folderB = try store.addFolder(title: "B", parentId: nil)

        let x = try store.addBookmark(title: "X", url: "https://x.example", parentId: folderA)
        let y = try store.addBookmark(title: "Y", url: "https://y.example", parentId: folderA)
        _ = try store.addBookmark(title: "Z", url: "https://z.example", parentId: folderB)

        try store.move(itemId: x, toParentId: folderB, index: 0)

        let remainingInA = try store.children(of: folderA)
        XCTAssertEqual(remainingInA.map(\.id), [y])
        XCTAssertEqual(remainingInA.first?.position, 0, "the gap left behind in the old parent must be closed")

        let nowInB = try store.children(of: folderB)
        XCTAssertEqual(nowInB.first?.id, x)
        XCTAssertEqual(nowInB.map(\.position), [0, 1])
    }

    func testDeletingFolderCascadesToChildren() throws {
        let folder = try store.addFolder(title: "Doomed", parentId: nil)
        let child = try store.addBookmark(title: "Child", url: "https://child.example", parentId: folder)

        try store.delete(itemId: folder)

        XCTAssertNil(try store.item(id: folder))
        XCTAssertNil(try store.item(id: child), "deleting a folder must cascade-delete its children")
    }

    func testDeleteRenumbersRemainingSiblings() throws {
        let a = try store.addBookmark(title: "A", url: "https://a.example", parentId: nil)
        let b = try store.addBookmark(title: "B", url: "https://b.example", parentId: nil)
        let c = try store.addBookmark(title: "C", url: "https://c.example", parentId: nil)

        try store.delete(itemId: b)

        let remaining = try store.children(of: nil)
        XCTAssertEqual(remaining.map(\.id), [a, c])
        XCTAssertEqual(remaining.map(\.position), [0, 1])
    }

    func testFolderAndBookmarkKindsPersistCorrectly() throws {
        let folderId = try store.addFolder(title: "Folder", parentId: nil)
        let bookmarkId = try store.addBookmark(title: "Bookmark", url: "https://example.com", parentId: nil)

        let folder = try store.item(id: folderId)
        let bookmark = try store.item(id: bookmarkId)

        XCTAssertEqual(folder?.kind, .folder)
        XCTAssertNil(folder?.url)
        XCTAssertEqual(bookmark?.kind, .bookmark)
        XCTAssertEqual(bookmark?.url, "https://example.com")
    }

    // MARK: - .bookmarkStoreDidChange

    /// Every mutating call posts once -- this is what lets MainMenuBuilder's
    /// Bookmarks menu refresh itself immediately rather than only on the
    /// next window-key-change (see AppDelegate's observer for this name).
    func testEachMutationPostsExactlyOneChangeNotification() throws {
        var postCount = 0
        let observer = NotificationCenter.default.addObserver(forName: .bookmarkStoreDidChange, object: store, queue: nil) { _ in
            postCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let folder = try store.addFolder(title: "Folder", parentId: nil)
        XCTAssertEqual(postCount, 1)

        let bookmark = try store.addBookmark(title: "A", url: "https://a.example", parentId: nil)
        XCTAssertEqual(postCount, 2)

        try store.rename(itemId: bookmark, title: "Renamed")
        XCTAssertEqual(postCount, 3)

        try store.updateURL(itemId: bookmark, url: "https://renamed.example")
        XCTAssertEqual(postCount, 4)

        try store.move(itemId: bookmark, toParentId: folder, index: 0)
        XCTAssertEqual(postCount, 5)

        try store.delete(itemId: bookmark)
        XCTAssertEqual(postCount, 6)
    }

    /// Read-only calls (children/item lookups) must never post -- otherwise
    /// every menu rebuild's own `children(of:)` read would recursively
    /// trigger another rebuild.
    func testReadOnlyCallsDoNotPostChangeNotification() throws {
        let folder = try store.addFolder(title: "Folder", parentId: nil)

        var postCount = 0
        let observer = NotificationCenter.default.addObserver(forName: .bookmarkStoreDidChange, object: store, queue: nil) { _ in
            postCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try store.children(of: nil)
        _ = try store.children(of: folder)
        _ = try store.item(id: folder)
        XCTAssertEqual(postCount, 0)
    }
}
