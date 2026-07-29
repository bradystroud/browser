import XCTest
@testable import BrowserCore

/// Fixtures are a synthetic multi-profile Safari layout this test builds
/// itself -- deliberately not against Brady's real Safari data, per
/// browser-ymx's own scope.
final class SafariProfileDiscoveryTests: XCTestCase {
    private var safariDir: URL!

    override func setUpWithError() throws {
        safariDir = try TestSupport.makeTempProfileDirectory()
    }

    override func tearDown() {
        TestSupport.removeQuietly(safariDir)
    }

    func testDiscoversEveryProfileUUIDSubdirectory() throws {
        let profilesDir = safariDir.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profilesDir.appendingPathComponent("11111111-1111-1111-1111-111111111111"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profilesDir.appendingPathComponent("22222222-2222-2222-2222-222222222222"), withIntermediateDirectories: true)
        // A stray non-directory file alongside the real profile folders
        // (e.g. a Finder .DS_Store) shouldn't be reported as a profile.
        try Data().write(to: profilesDir.appendingPathComponent(".DS_Store"))

        let ids = SafariProfileDiscovery.discoverProfileIds(safariDirectory: safariDir)

        XCTAssertEqual(ids, ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"])
    }

    func testNoProfilesFolderReturnsEmptyRatherThanThrowing() {
        // The normal, expected case for a Safari installation that has
        // never had a named profile created.
        XCTAssertEqual(SafariProfileDiscovery.discoverProfileIds(safariDirectory: safariDir), [])
    }

    /// Shaped like the query mac_apt documents against SafariTabs.db: a
    /// `bookmarks` table where a profile's own row has parent=0, type=1,
    /// subtype=2, with `external_uuid`/`title` holding the profile's UUID
    /// and display name -- see docs/ai-tasks/safari-import-notes.md for
    /// the full citation and confidence level.
    private func writeFixtureSafariTabsDatabase(at path: String, profiles: [(uuid: String, title: String)]) throws {
        let connection = try SQLiteConnection(path: path)
        try connection.execute("""
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, subtype INTEGER, external_uuid TEXT, title TEXT);
            """)
        for profile in profiles {
            let insert = try connection.prepare("INSERT INTO bookmarks (parent, type, subtype, external_uuid, title) VALUES (0, 1, 2, ?, ?);")
            try insert.bind(profile.uuid, at: 1)
            try insert.bind(profile.title, at: 2)
            try insert.step()
        }
        // A non-profile row (wrong subtype) shouldn't be picked up.
        let other = try connection.prepare("INSERT INTO bookmarks (parent, type, subtype, external_uuid, title) VALUES (0, 1, 99, 'not-a-profile', 'Not A Profile');")
        try other.step()
    }

    func testResolvesEveryProfileNameFromTheFixtureDatabase() throws {
        let dbPath = safariDir.appendingPathComponent("SafariTabs.db").path
        try writeFixtureSafariTabsDatabase(at: dbPath, profiles: [
            (uuid: "11111111-1111-1111-1111-111111111111", title: "Personal"),
            (uuid: "22222222-2222-2222-2222-222222222222", title: "Work"),
        ])

        let names = SafariProfileDiscovery.profileNames(fromCopiedSafariTabsDatabaseAt: dbPath)

        XCTAssertEqual(names["11111111-1111-1111-1111-111111111111"], "Personal")
        XCTAssertEqual(names["22222222-2222-2222-2222-222222222222"], "Work")
        XCTAssertEqual(names.count, 2, "the wrong-subtype row shouldn't be picked up as a profile")
    }

    func testMissingOrUnreadableDatabaseReturnsEmptyRatherThanThrowing() {
        let names = SafariProfileDiscovery.profileNames(fromCopiedSafariTabsDatabaseAt: "/nonexistent/SafariTabs.db")
        XCTAssertEqual(names, [:])
    }
}
