import XCTest
@testable import BrowserCore

final class SafariImportScannerTests: XCTestCase {
    private var root: URL!
    private var copies: URL!

    override func setUpWithError() throws {
        root = try TestSupport.makeTempProfileDirectory()
        copies = try TestSupport.makeTempProfileDirectory()
    }

    override func tearDown() {
        TestSupport.removeQuietly(root)
        TestSupport.removeQuietly(copies)
    }

    func testMissingProfileMetadataDoesNotOfferGuidDirectoriesAsProfiles() throws {
        let profiles = root.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("AAAAAAAA-0000-0000-0000-000000000001"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("History.db"))
        let sources = try XCTUnwrap(SafariImportScanner.locateSources(tempDirectory: copies, safariDirectories: [root]))
        XCTAssertEqual(sources.profiles.map(\.id), [SafariImportScanner.defaultProfileId])
        XCTAssertNotNil(sources.profiles.first?.historyPath)
        XCTAssertTrue(sources.profileMetadataUnavailable)
    }

    func testNamesAndDataFoldersSurviveUncheckpointedProfileMetadata() throws {
        let container = root.appendingPathComponent("Container")
        let legacy = root.appendingPathComponent("Legacy")
        for directory in [container, legacy] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let writer = try SQLiteConnection(path: container.appendingPathComponent("SafariTabs.db").path)
        try writer.execute("""
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE bookmarks (type INTEGER, subtype INTEGER, external_uuid TEXT, title TEXT, server_id TEXT);
            INSERT INTO bookmarks VALUES (1, 2, 'DefaultProfile', 'Personal', NULL);
            INSERT INTO bookmarks VALUES (1, 2, 'work-id', 'Work', 'work-data');
            """)
        let profiles = container.appendingPathComponent("Profiles")
        for name in ["work-id", "work-data", "orphan-cache"] {
            try FileManager.default.createDirectory(at: profiles.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: profiles.appendingPathComponent("work-data/History.db"))
        try Data().write(to: legacy.appendingPathComponent("History.db"))

        let sources = try XCTUnwrap(SafariImportScanner.locateSources(tempDirectory: copies, safariDirectories: [container, legacy]))
        XCTAssertEqual(sources.profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertEqual(sources.profiles.map(\.id), [SafariImportScanner.defaultProfileId, "work-id"])
        XCTAssertEqual(sources.profiles.last?.historyPath, profiles.appendingPathComponent("work-data/History.db"))
        XCTAssertEqual(sources.profiles.first?.historyPath, legacy.appendingPathComponent("History.db"))
        withExtendedLifetime(writer) {}
    }

    func testTriesSecondMetadataRootWhenFirstDatabaseIsInvalid() throws {
        let primary = root.appendingPathComponent("Primary")
        let secondary = root.appendingPathComponent("Secondary")
        for directory in [primary, secondary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("not a SQLite database".utf8).write(to: primary.appendingPathComponent("SafariTabs.db"))
        let writer = try SQLiteConnection(path: secondary.appendingPathComponent("SafariTabs.db").path)
        try writer.execute("""
            CREATE TABLE bookmarks (type INTEGER, subtype INTEGER, external_uuid TEXT, title TEXT, server_id TEXT);
            INSERT INTO bookmarks VALUES (1, 2, 'work-id', 'Work', 'work-data');
            """)
        let history = secondary.appendingPathComponent("Profiles/work-data/History.db")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: history)
        // A leftover directory in the first root must not hide data in the second.
        try FileManager.default.createDirectory(at: primary.appendingPathComponent("Profiles/cache-id"), withIntermediateDirectories: true)

        let sources = try XCTUnwrap(SafariImportScanner.locateSources(tempDirectory: copies, safariDirectories: [primary, secondary]))
        XCTAssertEqual(sources.profiles.map(\.displayName), ["Safari Default", "Work"])
        XCTAssertEqual(sources.profiles.last?.historyPath, history)
        withExtendedLifetime(writer) {}
    }

    func testInvalidMetadataIsReportedWithoutInventingProfiles() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profiles/leftover-id"), withIntermediateDirectories: true)
        try Data("invalid database".utf8).write(to: root.appendingPathComponent("SafariTabs.db"))
        let sources = try XCTUnwrap(SafariImportScanner.locateSources(tempDirectory: copies, safariDirectories: [root]))
        XCTAssertEqual(sources.profiles.map(\.id), [SafariImportScanner.defaultProfileId])
        XCTAssertTrue(sources.profileMetadataUnavailable)
    }

    func testUnreadableHistoryIsReportedInsteadOfLookingEmpty() throws {
        try Data("invalid SQLite database".utf8).write(to: root.appendingPathComponent("History.db"))
        let result = try SafariImportScanner.scan(safariDirectories: [root])
        defer { TestSupport.removeQuietly(result.tempDirectory) }
        let profile = try XCTUnwrap(result.profiles.first)
        XCTAssertTrue(profile.historyReadFailed)
        XCTAssertTrue(profile.hasUnavailableOnlyData)
        XCTAssertNil(profile.historyDatabasePath)
    }

    func testMissingHistoryIsAnEmptyProfileWithoutAReadFailure() throws {
        try PropertyListSerialization.data(fromPropertyList: ["Children": []], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Bookmarks.plist"))
        let result = try SafariImportScanner.scan(safariDirectories: [root])
        defer { TestSupport.removeQuietly(result.tempDirectory) }
        let profile = try XCTUnwrap(result.profiles.first)
        XCTAssertFalse(profile.historyReadFailed)
        XCTAssertEqual(profile.historyCount, 0)
    }

    func testSafariWithoutNamedProfilesCanStillImportRootHistory() throws {
        try Data().write(to: root.appendingPathComponent("History.db"))
        let sources = try XCTUnwrap(SafariImportScanner.locateSources(tempDirectory: copies, safariDirectories: [root]))
        XCTAssertEqual(sources.profiles.map(\.id), [SafariImportScanner.defaultProfileId])
    }
}
