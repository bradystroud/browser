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

    private func writeFixtureSafariTabsDatabase(at path: String, withServerId: Bool, profiles: [(uuid: String, title: String, serverId: String?)]) throws {
        let connection = try SQLiteConnection(path: path)
        let serverIdColumn = withServerId ? ", server_id TEXT" : ""
        try connection.execute("""
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, subtype INTEGER, external_uuid TEXT, title TEXT\(serverIdColumn));
            """)
        for profile in profiles {
            if withServerId {
                let insert = try connection.prepare("INSERT INTO bookmarks (parent, type, subtype, external_uuid, title, server_id) VALUES (0, 1, 2, ?, ?, ?);")
                try insert.bind(profile.uuid, at: 1)
                try insert.bind(profile.title, at: 2)
                try insert.bind(profile.serverId ?? "", at: 3)
                try insert.step()
            } else {
                let insert = try connection.prepare("INSERT INTO bookmarks (parent, type, subtype, external_uuid, title) VALUES (0, 1, 2, ?, ?);")
                try insert.bind(profile.uuid, at: 1)
                try insert.bind(profile.title, at: 2)
                try insert.step()
            }
        }
        // A non-profile row (wrong subtype) shouldn't be picked up.
        let other = try connection.prepare("INSERT INTO bookmarks (parent, type, subtype, external_uuid, title) VALUES (0, 1, 99, 'not-a-profile', 'Not A Profile');")
        try other.step()
    }

    func testReadsProfileRowsWithTheirDataFolder() throws {
        let dbPath = safariDir.appendingPathComponent("SafariTabs.db").path
        try writeFixtureSafariTabsDatabase(at: dbPath, withServerId: true, profiles: [
            (uuid: "DefaultProfile", title: "", serverId: nil),
            (uuid: "AAAAAAAA-0000-0000-0000-000000000001", title: "Work", serverId: "BBBBBBBB-0000-0000-0000-000000000001"),
        ])

        let records = SafariProfileDiscovery.profileRecords(fromCopiedSafariTabsDatabaseAt: dbPath)

        XCTAssertEqual(records, [
            .init(id: "DefaultProfile", name: "", dataFolderId: nil),
            .init(id: "AAAAAAAA-0000-0000-0000-000000000001", name: "Work", dataFolderId: "BBBBBBBB-0000-0000-0000-000000000001"),
        ])
    }

    func testSchemaWithoutServerIdStillYieldsRows() throws {
        let dbPath = safariDir.appendingPathComponent("SafariTabs.db").path
        try writeFixtureSafariTabsDatabase(at: dbPath, withServerId: false, profiles: [
            (uuid: "AAAAAAAA-0000-0000-0000-000000000001", title: "Work", serverId: nil),
        ])

        let records = SafariProfileDiscovery.profileRecords(fromCopiedSafariTabsDatabaseAt: dbPath)

        XCTAssertEqual(records, [.init(id: "AAAAAAAA-0000-0000-0000-000000000001", name: "Work", dataFolderId: nil)])
    }

    func testMissingOrUnreadableDatabaseReturnsEmptyRatherThanThrowing() {
        XCTAssertEqual(SafariProfileDiscovery.profileRecords(fromCopiedSafariTabsDatabaseAt: "/nonexistent/SafariTabs.db"), [])
    }

    // The real layout: Profiles/<external_uuid>/ holds only TopSites.plist,
    // Profiles/<server_id>/ holds History.db. One row per profile, pointing
    // at the server_id folder, and neither folder shows up a second time.
    func testJoinsEachProfileToItsServerIdFolderOnce() {
        let records: [SafariProfileDiscovery.ProfileRecord] = [
            .init(id: "DefaultProfile", name: "", dataFolderId: nil),
            .init(id: "3354CAE0-0000-0000-0000-000000000001", name: "Rove", dataFolderId: "7DE03CF3-0000-0000-0000-000000000001"),
        ]
        let folders = ["3354CAE0-0000-0000-0000-000000000001", "7de03cf3-0000-0000-0000-000000000001", "DefaultProfile"]

        let resolved = SafariProfileDiscovery.resolveProfiles(records: records, folderIds: folders)

        XCTAssertEqual(resolved, [
            .init(id: "3354CAE0-0000-0000-0000-000000000001", name: "Rove", dataFolderId: "7de03cf3-0000-0000-0000-000000000001"),
        ])
    }

    func testFallsBackToTheExternalUuidFolderWithoutAServerIdFolder() {
        let records: [SafariProfileDiscovery.ProfileRecord] = [.init(id: "AAAA", name: "Old", dataFolderId: nil)]

        XCTAssertEqual(
            SafariProfileDiscovery.resolveProfiles(records: records, folderIds: ["AAAA"]),
            [.init(id: "AAAA", name: "Old", dataFolderId: "AAAA")]
        )
    }

    func testUnclaimedFolderStillAppearsUnderItsUuid() {
        let resolved = SafariProfileDiscovery.resolveProfiles(records: [], folderIds: ["ORPHAN"])

        XCTAssertEqual(resolved, [.init(id: "ORPHAN", name: "ORPHAN", dataFolderId: "ORPHAN")])
    }

    func testProfileWithNoFolderOnThisMacHasNoDataFolder() {
        let records: [SafariProfileDiscovery.ProfileRecord] = [.init(id: "AAAA", name: "Elsewhere", dataFolderId: "BBBB")]

        XCTAssertEqual(
            SafariProfileDiscovery.resolveProfiles(records: records, folderIds: []),
            [.init(id: "AAAA", name: "Elsewhere", dataFolderId: nil)]
        )
    }
}
