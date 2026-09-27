import XCTest
@testable import BrowserCore

final class BookmarkImporterTests: XCTestCase {
    private var dir: URL!
    private var store: BookmarkStore!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        store = BookmarkStore(database: try Database(profileDirectory: dir))
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testImportsBookmarksAndRecreatesFolderStructure() throws {
        let nodes: [ImportedBookmarkNode] = [
            .bookmark(title: "Top", url: "https://top.example"),
            .folder(title: "Work", isFavoritesBar: false, children: [
                .bookmark(title: "GitHub", url: "https://github.com"),
                .folder(title: "Nested", isFavoritesBar: false, children: [
                    .bookmark(title: "Deep", url: "https://deep.example"),
                ]),
            ]),
        ]

        BookmarkImporter.importNodes(nodes, into: store, destinationParentId: nil, favoritesFolderId: nil)

        let topLevel = try store.children(of: nil)
        XCTAssertEqual(topLevel.map(\.title), ["Top", "Work"])
        XCTAssertEqual(topLevel[1].kind, .folder)

        let workChildren = try store.children(of: topLevel[1].id)
        XCTAssertEqual(workChildren.map(\.title), ["GitHub", "Nested"])

        let nestedChildren = try store.children(of: workChildren[1].id)
        XCTAssertEqual(nestedChildren.map(\.url), ["https://deep.example"])
    }

    func testImportsUnderAGivenDestinationFolderInsteadOfTopLevel() throws {
        let destinationId = try store.addFolder(title: "Imported from Safari", parentId: nil)
        let nodes: [ImportedBookmarkNode] = [.bookmark(title: "Example", url: "https://example.com")]

        BookmarkImporter.importNodes(nodes, into: store, destinationParentId: destinationId, favoritesFolderId: nil)

        XCTAssertEqual(try store.children(of: nil).count, 1, "only the destination folder itself should be at top level")
        let insideDestination = try store.children(of: destinationId)
        XCTAssertEqual(insideDestination.map(\.url), ["https://example.com"])
    }

    func testFavoritesBarFolderMergesIntoProvidedFavoritesFolderInstead() throws {
        let favoritesFolderId = try store.addFolder(title: "Favorites", parentId: nil)
        let nodes: [ImportedBookmarkNode] = [
            .folder(title: "Favorites", isFavoritesBar: true, children: [
                .bookmark(title: "Apple", url: "https://apple.com"),
            ]),
            .folder(title: "Work", isFavoritesBar: false, children: [
                .bookmark(title: "GitHub", url: "https://github.com"),
            ]),
        ]

        BookmarkImporter.importNodes(nodes, into: store, destinationParentId: nil, favoritesFolderId: favoritesFolderId)

        // No second "Favorites" folder should have been created -- its
        // bookmark landed inside the existing one instead.
        let topLevel = try store.children(of: nil)
        XCTAssertEqual(topLevel.map(\.title), ["Favorites", "Work"])

        let favoritesChildren = try store.children(of: favoritesFolderId)
        XCTAssertEqual(favoritesChildren.map(\.url), ["https://apple.com"])
    }

    func testDuplicateURLWithinTheSameFolderIsSkipped() throws {
        try store.addBookmark(title: "Already have this", url: "https://example.com", parentId: nil)

        let inserted = BookmarkImporter.importNodes(
            [.bookmark(title: "Example (import)", url: "https://example.com")],
            into: store, destinationParentId: nil, favoritesFolderId: nil
        )

        XCTAssertEqual(inserted, [], "a duplicate URL should not be reported as inserted")
        XCTAssertEqual(try store.children(of: nil).count, 1, "no second bookmark should have been created")
    }

    func testSameURLInDifferentFoldersIsNotConsideredADuplicate() throws {
        let folderId = try store.addFolder(title: "Elsewhere", parentId: nil)
        try store.addBookmark(title: "Existing", url: "https://example.com", parentId: folderId)

        let inserted = BookmarkImporter.importNodes(
            [.bookmark(title: "Example", url: "https://example.com")],
            into: store, destinationParentId: nil, favoritesFolderId: nil
        )

        XCTAssertEqual(inserted, ["https://example.com"], "dedup is scoped per-folder, not global")
    }

    func testReturnsExactlyTheURLsActuallyInsertedAcrossNestedFolders() throws {
        try store.addBookmark(title: "Dup", url: "https://dup.example", parentId: nil)

        let nodes: [ImportedBookmarkNode] = [
            .bookmark(title: "Dup", url: "https://dup.example"),
            .folder(title: "Sub", isFavoritesBar: false, children: [
                .bookmark(title: "New", url: "https://new.example"),
            ]),
        ]

        let inserted = BookmarkImporter.importNodes(nodes, into: store, destinationParentId: nil, favoritesFolderId: nil)
        XCTAssertEqual(inserted, ["https://new.example"])
    }

    func testImportingTheSameTreeTwiceReusesFoldersAndAddsNothing() throws {
        let nodes: [ImportedBookmarkNode] = [
            .folder(title: "Other Bookmarks", isFavoritesBar: false, children: [
                .bookmark(title: "A", url: "https://a.example"),
                .folder(title: "Nested", isFavoritesBar: false, children: [
                    .bookmark(title: "B", url: "https://b.example"),
                ]),
            ]),
        ]
        XCTAssertEqual(BookmarkImporter.importNodes(nodes, into: store, destinationParentId: nil, favoritesFolderId: nil).count, 2)
        XCTAssertEqual(BookmarkImporter.importNodes(nodes, into: store, destinationParentId: nil, favoritesFolderId: nil), [])

        let topLevel = try store.children(of: nil)
        XCTAssertEqual(topLevel.map(\.title), ["Other Bookmarks"])
        let inside = try store.children(of: topLevel[0].id)
        XCTAssertEqual(inside.map(\.title), ["A", "Nested"])
        XCTAssertEqual(try store.children(of: inside[1].id).map(\.title), ["B"])
    }

    func testFolderMergesOnlyWithAFolderNotABookmarkOfTheSameTitle() throws {
        try store.addBookmark(title: "Work", url: "https://work.example", parentId: nil)
        BookmarkImporter.importNodes(
            [.folder(title: "Work", isFavoritesBar: false, children: [.bookmark(title: "C", url: "https://c.example")])],
            into: store, destinationParentId: nil, favoritesFolderId: nil
        )
        XCTAssertEqual(try store.children(of: nil).map(\.kind), [.bookmark, .folder])
    }
}
