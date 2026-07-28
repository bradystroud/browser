import XCTest
@testable import BrowserCore

final class SafariBookmarksPlistParserTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafariBookmarksPlistParserTests-\(UUID().uuidString).plist")
    }

    override func tearDown() {
        TestSupport.removeQuietly(fileURL)
    }

    /// A synthetic plist shaped like Safari's real Bookmarks.plist: a root
    /// with a Children array, a "BookmarksBar" folder identified via
    /// WebBookmarkIdentifier (Safari's favorites bar), a nested folder, and
    /// leaf bookmarks whose display title lives under URIDictionary.title
    /// rather than a top-level "Title" key.
    private func writeFixturePlist() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": "",
            "Children": [
                [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "WebBookmarkIdentifier": "BookmarksBar",
                    "Title": "Favorites",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://apple.com",
                            "URIDictionary": ["title": "Apple"],
                        ],
                    ],
                ],
                [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": "Work",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://github.com",
                            "URIDictionary": ["title": "GitHub"],
                        ],
                    ],
                ],
                [
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "URLString": "https://toplevel.example",
                    "URIDictionary": ["title": "Top level"],
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: fileURL)
    }

    func testParsesRealisticSafariShapedPlist() throws {
        try writeFixturePlist()
        let nodes = try SafariBookmarksPlistParser.parse(fileURL: fileURL)

        XCTAssertEqual(nodes.count, 3)

        guard case .folder(let title, let isFavoritesBar, let children) = nodes[0] else {
            return XCTFail("expected first node to be the Favorites folder")
        }
        XCTAssertEqual(title, "Favorites")
        XCTAssertTrue(isFavoritesBar, "WebBookmarkIdentifier == BookmarksBar should mark this as the favorites-bar folder")
        XCTAssertEqual(children, [.bookmark(title: "Apple", url: "https://apple.com")])

        guard case .folder(let workTitle, let workIsBar, let workChildren) = nodes[1] else {
            return XCTFail("expected second node to be the Work folder")
        }
        XCTAssertEqual(workTitle, "Work")
        XCTAssertFalse(workIsBar)
        XCTAssertEqual(workChildren, [.bookmark(title: "GitHub", url: "https://github.com")])

        XCTAssertEqual(nodes[2], .bookmark(title: "Top level", url: "https://toplevel.example"))
    }

    func testMissingFileThrowsFileNotReadable() {
        // Never written -- simulates both "file doesn't exist" and a real
        // TCC/Full-Disk-Access denial, which NSDictionary(contentsOf:)
        // reports identically (nil, no exception) -- confirmed empirically
        // against a real, permission-denied Bookmarks.plist during
        // development of this feature.
        XCTAssertThrowsError(try SafariBookmarksPlistParser.parse(fileURL: fileURL)) { error in
            XCTAssertEqual(error as? SafariBookmarksPlistParser.ReadError, .fileNotReadable)
        }
    }

    func testFavoritesBarDetectedByTitleWhenIdentifierMissing() throws {
        let plist: [String: Any] = [
            "Children": [
                [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": "Favorites",
                    "Children": [[String: Any]](),
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: fileURL)

        let nodes = try SafariBookmarksPlistParser.parse(fileURL: fileURL)
        guard case .folder(_, let isFavoritesBar, _) = nodes.first else {
            return XCTFail("expected a folder")
        }
        XCTAssertTrue(isFavoritesBar)
    }
}

extension SafariBookmarksPlistParser.ReadError: Equatable {
    public static func == (lhs: SafariBookmarksPlistParser.ReadError, rhs: SafariBookmarksPlistParser.ReadError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotReadable, .fileNotReadable), (.unexpectedFormat, .unexpectedFormat):
            return true
        default:
            return false
        }
    }
}
