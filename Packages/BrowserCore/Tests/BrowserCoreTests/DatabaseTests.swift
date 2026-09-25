import XCTest
@testable import BrowserCore

final class DatabaseTests: XCTestCase {
    func testMigrationFromEmptyCreatesAllTables() throws {
        let dir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(dir) }

        let db = try Database(profileDirectory: dir)

        // Exercise one statement against each table the migration is
        // supposed to create; any missing table throws immediately.
        try db.perform { conn in
            try conn.execute("SELECT * FROM history_urls LIMIT 1;")
            try conn.execute("SELECT * FROM history_visits LIMIT 1;")
            try conn.execute("SELECT * FROM bookmark_items LIMIT 1;")
            try conn.execute("SELECT * FROM downloads LIMIT 1;")
        }
    }

    func testConnectionsWaitOutLocksAndReadWriteOnesSyncNormally() throws {
        let dir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(dir) }

        func pragma(_ name: String, _ db: Database) throws -> Int {
            try db.perform { conn in
                let stmt = try conn.prepare("PRAGMA \(name);")
                _ = try stmt.step()
                return Int(stmt.int(0))
            }
        }

        let readWrite = try Database(profileDirectory: dir)
        XCTAssertEqual(try pragma("busy_timeout", readWrite), Int(SQLiteConnection.busyTimeoutMilliseconds))
        XCTAssertEqual(try pragma("synchronous", readWrite), 1, "1 is NORMAL")

        let readOnly = try Database.openExistingReadOnly(profileDirectory: dir)
        XCTAssertEqual(try pragma("busy_timeout", readOnly), Int(SQLiteConnection.busyTimeoutMilliseconds))
    }

    func testInMemoryDatabaseHasTheFullSchemaAndIsNotShared() throws {
        let first = HistoryStore(database: try Database.inMemory())
        try first.recordVisit(url: "https://example.com", title: "Example")
        XCTAssertEqual(try first.autocomplete(query: "example").count, 1)

        let second = HistoryStore(database: try Database.inMemory())
        XCTAssertTrue(try second.autocomplete(query: "example").isEmpty)
    }

    func testReadOnlyOpenNeverCreatesAMissingDatabase() throws {
        let dir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(dir) }
        let profileDir = dir.appendingPathComponent("never-launched")

        XCTAssertThrowsError(try Database.openExistingReadOnly(profileDirectory: profileDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileDir.path))
    }

    func testReadOnlyOpenReadsAnExistingDatabase() throws {
        let dir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(dir) }
        try HistoryStore(database: try Database(profileDirectory: dir))
            .recordVisit(url: "https://example.com", title: "Example")

        let reader = HistoryStore(database: try Database.openExistingReadOnly(profileDirectory: dir))
        XCTAssertEqual(try reader.autocomplete(query: "example").map(\.url), ["https://example.com"])
        XCTAssertThrowsError(try reader.recordVisit(url: "https://other.example", title: nil))
    }

    func testReopeningExistingDatabaseIsIdempotent() throws {
        let dir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(dir) }

        let db1 = try Database(profileDirectory: dir)
        let history = HistoryStore(database: db1)
        try history.recordVisit(url: "https://example.com", title: "Example")

        // Reopening the same profile directory (simulating an app relaunch)
        // must not re-run migrations destructively or lose data.
        let db2 = try Database(profileDirectory: dir)
        let entries = try HistoryStore(database: db2).entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.url, "https://example.com")
    }

    func testConcurrentReadWriteSafety() throws {
        let dir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(dir) }

        let db = try Database(profileDirectory: dir)
        let history = HistoryStore(database: db)

        let iterations = 200
        let writerDone = expectation(description: "writer finished")
        let readerDone = expectation(description: "reader finished")

        DispatchQueue.global().async {
            for i in 0..<iterations {
                try? history.recordVisit(url: "https://example.com/\(i)", title: "Page \(i)")
            }
            writerDone.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<iterations {
                _ = try? history.entries(limit: 10)
            }
            readerDone.fulfill()
        }

        wait(for: [writerDone, readerDone], timeout: 30)

        let finalCount = try history.entries(limit: iterations + 10).count
        XCTAssertEqual(finalCount, iterations, "every write should have landed with no corruption/loss under concurrent access")
    }
}
