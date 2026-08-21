import XCTest
@testable import BrowserCore

final class MigrationTests: XCTestCase {
    func testFreshDatabaseEndsAtLatestSchemaVersion() throws {
        let path = try TestSupport.makeTempProfileDirectory().appendingPathComponent("browser.db").path
        let conn = try SQLiteConnection(path: path)

        try Migrations.run(on: conn)

        XCTAssertEqual(conn.userVersion, Int32(Migrations.migrations.count))
    }

    func testRunningMigrationsTwiceIsANoOp() throws {
        let path = try TestSupport.makeTempProfileDirectory().appendingPathComponent("browser.db").path
        let conn = try SQLiteConnection(path: path)

        try Migrations.run(on: conn)
        // A second run against an already-current schema must not attempt
        // to re-create tables that already exist.
        try Migrations.run(on: conn)

        XCTAssertEqual(conn.userVersion, Int32(Migrations.migrations.count))
    }

    /// Every database on a real machine today is at some earlier version, so
    /// "upgrades in place, keeping what was already there" is the case that
    /// actually runs -- the fresh-install path above never touches it.
    func testAnExistingDatabaseUpgradesInPlaceWithoutLosingData() throws {
        let path = try TestSupport.makeTempProfileDirectory().appendingPathComponent("browser.db").path
        let conn = try SQLiteConnection(path: path)

        // Bring the database up to version 1 only, then put a row in it, as
        // an install from before any later migration existed would have.
        try conn.withTransaction {
            try Migrations.migrations[0](conn)
            try conn.setUserVersion(1)
        }
        let insert = try conn.prepare("""
            INSERT INTO bookmark_items (parent_id, kind, title, url, position, created_at)
            VALUES (NULL, 'bookmark', 'Kept', 'https://example.com', 0, 0);
            """)
        try insert.step()

        try Migrations.run(on: conn)

        XCTAssertEqual(conn.userVersion, Int32(Migrations.migrations.count))
        let kept = try conn.prepare("SELECT title FROM bookmark_items;")
        XCTAssertTrue(try kept.step())
        XCTAssertEqual(kept.text(0), "Kept")
        // And the table the newer migration adds is really there.
        let added = try conn.prepare("SELECT COUNT(*) FROM reading_list_items;")
        XCTAssertTrue(try added.step())
        XCTAssertEqual(added.int(0), 0)
    }
}
