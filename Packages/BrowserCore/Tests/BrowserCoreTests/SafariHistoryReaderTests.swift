import XCTest
@testable import BrowserCore

/// Fixtures are built with the same SQLiteConnection this package already
/// uses to talk to its own database, in plain (non-read-only) mode --
/// deliberately not against Brady's real Safari History.db (never test
/// against real user data), per browser-ymx's own scope.
final class SafariHistoryReaderTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafariHistoryReaderTests-\(UUID().uuidString).db").path
    }

    override func tearDown() {
        TestSupport.removeQuietly(URL(fileURLWithPath: dbPath))
    }

    /// Shaped like Safari's real History.db: history_items (one row per
    /// distinct URL) joined to history_visits (one row per visit event,
    /// its own title snapshot, and a Mac-absolute-time visit_time).
    private func writeFixtureDatabase(visits: [(url: String, title: String, macAbsoluteTime: Double)]) throws {
        let connection = try SQLiteConnection(path: dbPath)
        try connection.execute("""
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, title TEXT, visit_time REAL);
            """)
        var urlIds: [String: Int64] = [:]
        for visit in visits {
            let urlId: Int64
            if let existing = urlIds[visit.url] {
                urlId = existing
            } else {
                let insert = try connection.prepare("INSERT INTO history_items (url) VALUES (?);")
                try insert.bind(visit.url, at: 1)
                try insert.step()
                urlId = connection.lastInsertRowID
                urlIds[visit.url] = urlId
            }
            let visitInsert = try connection.prepare("INSERT INTO history_visits (history_item, title, visit_time) VALUES (?, ?, ?);")
            try visitInsert.bind(urlId, at: 1)
            try visitInsert.bind(visit.title, at: 2)
            try visitInsert.bind(visit.macAbsoluteTime, at: 3)
            try visitInsert.step()
        }
    }

    func testReadsEveryVisitRowWithItsJoinedURL() throws {
        try writeFixtureDatabase(visits: [
            (url: "https://example.com", title: "Example", macAbsoluteTime: 700_000_000),
            (url: "https://example.com", title: "Example (again)", macAbsoluteTime: 700_003_600),
            (url: "https://other.example", title: "Other", macAbsoluteTime: 700_007_200),
        ])

        let visits = try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: dbPath)

        XCTAssertEqual(visits.count, 3)
        XCTAssertEqual(visits.filter { $0.url == "https://example.com" }.count, 2)
    }

    func testMacAbsoluteTimeConvertsToTheSameCalendarInstantAsFoundationsReferenceDate() throws {
        // 2001-01-01 00:00:00 UTC plus exactly one day, expressed in Mac
        // absolute time (seconds since that same reference date) --
        // Foundation's own timeIntervalSinceReferenceDate epoch is defined
        // identically, so this should convert with no manual offset.
        let oneDayInSeconds: Double = 86_400
        try writeFixtureDatabase(visits: [
            (url: "https://example.com", title: "Example", macAbsoluteTime: oneDayInSeconds),
        ])

        let visits = try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: dbPath)

        let expected = Date(timeIntervalSinceReferenceDate: oneDayInSeconds)
        XCTAssertEqual(visits.first?.visitTime, expected)
    }

    func testMissingFileThrowsFileNotReadable() {
        XCTAssertThrowsError(try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: "/nonexistent/path/History.db")) { error in
            XCTAssertEqual(error as? SafariHistoryReader.ReadError, .fileNotReadable)
        }
    }

    func testEmptyURLRowsAreSkipped() throws {
        try writeFixtureDatabase(visits: [
            (url: "", title: "No URL", macAbsoluteTime: 700_000_000),
            (url: "https://real.example", title: "Real", macAbsoluteTime: 700_000_000),
        ])

        let visits = try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: dbPath)

        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.url, "https://real.example")
    }
}

extension SafariHistoryReader.ReadError: Equatable {
    public static func == (lhs: SafariHistoryReader.ReadError, rhs: SafariHistoryReader.ReadError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotReadable, .fileNotReadable), (.unexpectedFormat, .unexpectedFormat):
            return true
        default:
            return false
        }
    }
}
