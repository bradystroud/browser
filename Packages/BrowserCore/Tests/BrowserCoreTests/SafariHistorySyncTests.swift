import XCTest
@testable import BrowserCore

/// Every Safari database here is a synthetic fixture shaped like Safari's
/// History.db, never a real one.
final class SafariHistorySyncTests: XCTestCase {
    private var dir: URL!
    private var safariDbPath: String!
    private var safari: SQLiteConnection!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        safariDbPath = dir.appendingPathComponent("History.db").path
        safari = try SQLiteConnection(path: safariDbPath)
        try safari.execute("""
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, title TEXT, visit_time REAL);
            """)
    }

    override func tearDown() {
        safari = nil
        TestSupport.removeQuietly(dir)
    }

    private func addSafariVisit(id: Int64? = nil, url: String, title: String? = nil, time: Double) throws {
        let select = try safari.prepare("SELECT id FROM history_items WHERE url = ?;")
        try select.bind(url, at: 1)
        let itemId: Int64
        if try select.step() {
            itemId = select.int64(0)
        } else {
            let insert = try safari.prepare("INSERT INTO history_items (url) VALUES (?);")
            try insert.bind(url, at: 1)
            try insert.step()
            itemId = safari.lastInsertRowID
        }
        let visit = try safari.prepare("INSERT INTO history_visits (id, history_item, title, visit_time) VALUES (?, ?, ?, ?);")
        if let id { try visit.bind(id, at: 1) } else { try visit.bindNull(at: 1) }
        try visit.bind(itemId, at: 2)
        try visit.bind(title, at: 3)
        try visit.bind(time, at: 4)
        try visit.step()
    }

    private func read(after cursor: SafariHistorySyncCursor) throws -> (visits: [SafariHistoryVisit], cursor: SafariHistorySyncCursor) {
        try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: safariDbPath, after: cursor)
    }

    // MARK: - Incremental reading

    func testFirstReadReturnsEveryVisitAndAdvancesBothMarks() throws {
        try addSafariVisit(url: "https://a.example", time: 700_000_000)
        try addSafariVisit(url: "https://b.example", time: 700_000_100)

        let result = try read(after: .start)

        XCTAssertEqual(result.visits.map(\.url).sorted(), ["https://a.example", "https://b.example"])
        XCTAssertEqual(result.cursor, SafariHistorySyncCursor(lastVisitId: 2, lastVisitTime: 700_000_100))
    }

    func testSecondReadReturnsOnlyNewVisits() throws {
        try addSafariVisit(url: "https://a.example", time: 700_000_000)
        let first = try read(after: .start)

        try addSafariVisit(url: "https://b.example", time: 700_000_500)
        let second = try read(after: first.cursor)

        XCTAssertEqual(second.visits.map(\.url), ["https://b.example"])
        XCTAssertTrue(try read(after: second.cursor).visits.isEmpty)
    }

    func testLateICloudVisitWithAnOlderTimestampIsStillRead() throws {
        try addSafariVisit(url: "https://a.example", time: 700_000_000)
        let first = try read(after: .start)

        // Another device's visit arrives later but carries its own,
        // earlier visit time.
        try addSafariVisit(url: "https://phone.example", time: 699_000_000)
        let second = try read(after: first.cursor)

        XCTAssertEqual(second.visits.map(\.url), ["https://phone.example"])
        XCTAssertEqual(second.cursor.lastVisitTime, 700_000_000, "An older visit never moves the time mark back")
    }

    func testReusedIdWithANewerTimestampIsStillRead() throws {
        try addSafariVisit(id: 1, url: "https://a.example", time: 700_000_000)
        try addSafariVisit(id: 2, url: "https://b.example", time: 700_000_100)
        let first = try read(after: .start)

        try safari.execute("DELETE FROM history_visits WHERE id = 2;")
        try addSafariVisit(id: 2, url: "https://c.example", time: 700_000_900)
        let second = try read(after: first.cursor)

        XCTAssertEqual(second.visits.map(\.url), ["https://c.example"])
    }

    func testRebuiltDatabaseFallsBackToTheTimeMark() throws {
        let cursor = SafariHistorySyncCursor(lastVisitId: 5_000, lastVisitTime: 700_000_000)
        try addSafariVisit(url: "https://old.example", time: 699_999_000)
        try addSafariVisit(url: "https://new.example", time: 700_000_050)

        let result = try read(after: cursor)

        XCTAssertEqual(result.visits.map(\.url), ["https://new.example"])
        XCTAssertEqual(result.cursor.lastVisitId, 2, "The id mark follows the rebuilt file")
    }

    func testEmptyDatabaseKeepsTheCursor() throws {
        let result = try read(after: .start)
        XCTAssertTrue(result.visits.isEmpty)
        XCTAssertEqual(result.cursor, .start)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try SafariHistoryReader.readVisits(fromCopiedDatabaseAt: "/nonexistent/History.db", after: .start)) { error in
            XCTAssertEqual(error as? SafariHistoryReader.ReadError, .fileNotReadable)
        }
    }

    // MARK: - Mapping

    private let eligible: Set<String> = ["personal-id", "work-id"]

    func testUnmappedSafariProfileGoesToTheDefault() {
        let settings = SafariHistorySyncSettings()
        XCTAssertEqual(settings.destinationProfileId(forSafariProfile: "safari-default", eligibleProfileIds: eligible, defaultProfileId: "personal-id"), "personal-id")
    }

    func testMappedSafariProfileGoesToItsProfile() {
        let settings = SafariHistorySyncSettings(targets: ["UUID-A": .profile(id: "work-id")])
        XCTAssertEqual(settings.destinationProfileId(forSafariProfile: "UUID-A", eligibleProfileIds: eligible, defaultProfileId: "personal-id"), "work-id")
        XCTAssertEqual(settings.destinationProfileId(forSafariProfile: "UUID-B", eligibleProfileIds: eligible, defaultProfileId: "personal-id"), "personal-id")
    }

    func testSkippedSafariProfileGoesNowhere() {
        let settings = SafariHistorySyncSettings(targets: ["UUID-A": .skip])
        XCTAssertNil(settings.destinationProfileId(forSafariProfile: "UUID-A", eligibleProfileIds: eligible, defaultProfileId: "personal-id"))
    }

    func testMappingToAProfileThatIsNotEligibleFallsBackToTheDefault() {
        let settings = SafariHistorySyncSettings(targets: [
            "UUID-A": .profile(id: "deleted-id"),
            "UUID-B": .profile(id: "private-1234"),
        ])
        XCTAssertEqual(settings.destinationProfileId(forSafariProfile: "UUID-A", eligibleProfileIds: eligible, defaultProfileId: "personal-id"), "personal-id")
        XCTAssertEqual(settings.destinationProfileId(forSafariProfile: "UUID-B", eligibleProfileIds: eligible, defaultProfileId: "personal-id"), "personal-id")
    }

    func testIneligibleDefaultMeansNoDestination() {
        let settings = SafariHistorySyncSettings()
        XCTAssertNil(settings.destinationProfileId(forSafariProfile: "UUID-A", eligibleProfileIds: eligible, defaultProfileId: "private-1234"))
        XCTAssertNil(settings.destinationProfileId(forSafariProfile: "UUID-A", eligibleProfileIds: eligible, defaultProfileId: nil))
    }

    func testCursorsAreKeptPerSafariAndBrowserProfilePair() {
        var settings = SafariHistorySyncSettings()
        let cursor = SafariHistorySyncCursor(lastVisitId: 9, lastVisitTime: 1)
        settings.cursors[SafariHistorySyncSettings.cursorKey(safariProfileId: "UUID-A", browserProfileId: "personal-id")] = cursor

        XCTAssertEqual(settings.cursor(safariProfileId: "UUID-A", browserProfileId: "personal-id"), cursor)
        XCTAssertEqual(settings.cursor(safariProfileId: "UUID-A", browserProfileId: "work-id"), .start)
    }

    func testSettingsRoundTripAndToleratesMissingKeys() throws {
        let settings = SafariHistorySyncSettings(
            isEnabled: true,
            targets: ["UUID-A": .profile(id: "work-id"), "UUID-B": .skip, "safari-default": .defaultProfile],
            cursors: ["UUID-A>work-id": SafariHistorySyncCursor(lastVisitId: 3, lastVisitTime: 700_000_000.25)]
        )
        let decoded = try JSONDecoder().decode(SafariHistorySyncSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)

        let empty = try JSONDecoder().decode(SafariHistorySyncSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, SafariHistorySyncSettings())
        XCTAssertFalse(empty.isEnabled, "Sync is off until the user turns it on")
    }

    // MARK: - Storing without duplicates

    func testImportSkippingExistingNeverDuplicatesAVisit() throws {
        let profileDir = try TestSupport.makeTempProfileDirectory()
        defer { TestSupport.removeQuietly(profileDir) }
        let store = HistoryStore(database: try Database(profileDirectory: profileDir))
        let time = Date(timeIntervalSinceReferenceDate: 700_000_000.1234)

        // An earlier one-time Safari import already brought this visit in.
        try store.importVisits([(url: "https://a.example", title: "A", visitTime: time)])

        let inserted = try store.importVisitsSkippingExisting([
            (url: "https://a.example", title: "A", visitTime: time),
            (url: "https://a.example", title: "A", visitTime: time.addingTimeInterval(60)),
            (url: "https://b.example", title: "B", visitTime: time),
        ])

        XCTAssertEqual(inserted, 2)
        let entries = try store.entries()
        XCTAssertEqual(entries.first { $0.url == "https://a.example" }?.visitCount, 2)
        XCTAssertEqual(entries.first { $0.url == "https://b.example" }?.visitCount, 1)

        XCTAssertEqual(try store.importVisitsSkippingExisting([(url: "https://b.example", title: nil, visitTime: time)]), 0)
    }
}
