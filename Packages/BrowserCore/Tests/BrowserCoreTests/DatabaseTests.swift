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
