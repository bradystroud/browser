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
}
