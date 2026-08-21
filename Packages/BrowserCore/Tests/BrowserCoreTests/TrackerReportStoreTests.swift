import XCTest
@testable import BrowserCore

final class TrackerReportStoreTests: XCTestCase {
    private var dir: URL!
    private var store: TrackerReportStore!

    /// A fixed "now" so every window/pruning assertion is about the code
    /// rather than about what time the test suite happened to run.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        store = try TrackerReportStore(profileDirectory: dir)
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    // MARK: - Helpers

    private func day(_ offset: Int) -> Int {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: now)!
        return TrackerReportStore.startOfDay(for: date)
    }

    private func tally(_ dayOffset: Int, _ pageHost: String, _ trackerDomain: String) -> TrackerBlockTally {
        TrackerBlockTally(day: day(dayOffset), pageHost: pageHost, trackerDomain: trackerDomain)
    }

    // MARK: - Aggregation

    func testAddTalliesAccumulatesRatherThanReplacing() throws {
        try store.addTallies([tally(0, "news.example", "doubleclick.net"): 3], now: now)
        try store.addTallies([tally(0, "news.example", "doubleclick.net"): 4], now: now)

        let summary = try store.summary(now: now)
        XCTAssertEqual(summary.requestCount, 7)
        // Still one tracker on one site: the same tally arriving twice is
        // more requests, not more trackers.
        XCTAssertEqual(summary.trackerCount, 1)
        XCTAssertEqual(summary.siteCount, 1)
    }

    func testTrackerCountIsDistinctDomainsNotRequests() throws {
        try store.addTallies([
            tally(0, "news.example", "doubleclick.net"): 40,
            tally(0, "news.example", "scorecardresearch.com"): 2,
        ], now: now)

        let summary = try store.summary(now: now)
        // The headline number a user reads as "trackers blocked" must be 2,
        // never 42 -- the whole reason this store aggregates by domain.
        XCTAssertEqual(summary.trackerCount, 2)
        XCTAssertEqual(summary.requestCount, 42)
    }

    func testSameTrackerOnManySitesCountsOnceAsATracker() throws {
        try store.addTallies([
            tally(0, "news.example", "doubleclick.net"): 5,
            tally(0, "shop.example", "doubleclick.net"): 5,
            tally(0, "blog.example", "doubleclick.net"): 5,
        ], now: now)

        let summary = try store.summary(now: now)
        XCTAssertEqual(summary.trackerCount, 1)
        XCTAssertEqual(summary.siteCount, 3)
        XCTAssertEqual(summary.topTrackers.first?.siteCount, 3)
        XCTAssertEqual(summary.topTrackers.first?.requestCount, 15)
    }

    func testTopTrackersOrderBySitesBeforeRequests() throws {
        try store.addTallies([
            // Loud on one page.
            tally(0, "news.example", "loud.example"): 500,
            // Quieter, but following the user across three sites.
            tally(0, "news.example", "everywhere.example"): 1,
            tally(0, "shop.example", "everywhere.example"): 1,
            tally(0, "blog.example", "everywhere.example"): 1,
        ], now: now)

        let summary = try store.summary(now: now)
        XCTAssertEqual(summary.topTrackers.first?.trackerDomain, "everywhere.example")
        XCTAssertEqual(summary.mostContactedTracker?.trackerDomain, "everywhere.example")
    }

    // MARK: - Retention

    func testWindowExcludesRowsOlderThanRetention() throws {
        try store.addTallies([tally(-29, "news.example", "old.example"): 1], now: now)
        try store.addTallies([tally(0, "news.example", "new.example"): 1], now: now)

        // 30 buckets including today, so day -29 is the oldest kept.
        let summary = try store.summary(now: now)
        XCTAssertEqual(summary.trackerCount, 2)

        // One day later, the -29 bucket has fallen out of the window.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(try store.summary(now: tomorrow).trackerCount, 1)
    }

    func testAddPrunesRowsPastRetention() throws {
        try store.addTallies([tally(-40, "news.example", "ancient.example"): 9], now: now)
        // The write above is itself outside the window and is dropped rather
        // than stored -- a privacy feature should not hold what it will not
        // show, not even briefly.
        XCTAssertEqual(try store.summary(now: now).requestCount, 0)
    }

    func testPruningDeletesRatherThanHides() throws {
        // Land a row legitimately, then advance far enough that it is past
        // retention and force another write so pruning runs.
        try store.addTallies([tally(0, "news.example", "old.example"): 3], now: now)
        let muchLater = Calendar.current.date(byAdding: .day, value: 45, to: now)!
        try store.addTallies([
            TrackerBlockTally(
                day: TrackerReportStore.startOfDay(for: muchLater),
                pageHost: "news.example",
                trackerDomain: "new.example"
            ): 1,
        ], now: muchLater)

        XCTAssertEqual(try store.summary(now: muchLater).trackerCount, 1)

        // Not merely filtered out of the window -- gone from the table. This
        // query's cutoff is computed from the ORIGINAL now, so its window
        // still covers the day the old row was written to: an unpruned row
        // would answer here, and does not.
        let reachingBack = try store.trackers(forPageHost: "news.example", now: now)
        XCTAssertFalse(reachingBack.contains { $0.trackerDomain == "old.example" })
    }

    // MARK: - Per-site

    func testTrackersForPageHostIsScopedToThatSite() throws {
        try store.addTallies([
            tally(0, "news.example", "doubleclick.net"): 7,
            tally(0, "news.example", "scorecardresearch.com"): 2,
            tally(0, "shop.example", "other.example"): 99,
        ], now: now)

        let entries = try store.trackers(forPageHost: "news.example", now: now)
        XCTAssertEqual(entries.map(\.trackerDomain), ["doubleclick.net", "scorecardresearch.com"])
        XCTAssertEqual(entries.first?.requestCount, 7)
    }

    func testTrackersForPageHostIsCaseInsensitive() throws {
        try store.addTallies([tally(0, "news.example", "doubleclick.net"): 1], now: now)
        XCTAssertEqual(try store.trackers(forPageHost: "News.Example", now: now).count, 1)
    }

    // MARK: - Clearing and persistence

    func testClearForgetsEverything() throws {
        try store.addTallies([tally(0, "news.example", "doubleclick.net"): 5], now: now)
        try store.clear()

        let summary = try store.summary(now: now)
        XCTAssertEqual(summary.requestCount, 0)
        XCTAssertEqual(summary.trackerCount, 0)
        XCTAssertTrue(summary.isEmpty)
    }

    func testCountsSurviveReopening() throws {
        try store.addTallies([tally(0, "news.example", "doubleclick.net"): 5], now: now)
        store = nil

        let reopened = try TrackerReportStore(profileDirectory: dir)
        XCTAssertEqual(try reopened.summary(now: now).requestCount, 5)
    }

    func testUsesItsOwnDatabaseFileNotBrowserDB() throws {
        try store.addTallies([tally(0, "news.example", "doubleclick.net"): 1], now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("privacy-report.db").path))
        // The durable stores' file must not be created as a side effect of
        // the report existing -- the two are deliberately separate.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("browser.db").path))
    }

    func testDailyTotalsAreGroupedByDay() throws {
        try store.addTallies([
            tally(-1, "news.example", "a.example"): 2,
            tally(0, "news.example", "a.example"): 3,
            tally(0, "news.example", "b.example"): 1,
        ], now: now)

        let days = try store.summary(now: now).days
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.requestCount, 2)
        XCTAssertEqual(days.last?.trackerCount, 2)
        XCTAssertEqual(days.last?.requestCount, 4)
    }

    func testEmptyBatchIsANoOp() throws {
        try store.addTallies([:], now: now)
        XCTAssertTrue(try store.summary(now: now).isEmpty)
    }
}
