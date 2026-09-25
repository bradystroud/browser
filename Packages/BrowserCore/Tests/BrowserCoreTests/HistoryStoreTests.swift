import XCTest
@testable import BrowserCore

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        store = HistoryStore(database: try Database(profileDirectory: dir))
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testUpdateTitleReplacesTitleRecordedAtCommit() throws {
        try store.recordVisit(url: "https://example.com", title: nil)
        try store.updateTitle(url: "https://example.com", title: "Example Domain")
        try store.updateTitle(url: "https://example.com", title: "")
        try store.updateTitle(url: "https://never-visited.example", title: "Ignored")

        let results = try store.autocomplete(query: "example")
        XCTAssertEqual(results.map(\.url), ["https://example.com"])
        XCTAssertEqual(results.first?.title, "Example Domain")
    }

    func testUpdateTitleSkipsWriteWhenTitleIsUnchanged() throws {
        try store.recordVisit(url: "https://example.com", title: nil)

        XCTAssertTrue(try store.setTitle(url: "https://example.com", title: "Example Domain"))
        XCTAssertFalse(try store.setTitle(url: "https://example.com", title: "Example Domain"))
        XCTAssertTrue(try store.setTitle(url: "https://example.com", title: "(1) Example Domain"))
        XCTAssertFalse(try store.setTitle(url: "https://never-visited.example", title: "Ignored"))

        try store.updateTitle(url: "https://example.com", title: "(1) Example Domain")
        XCTAssertEqual(try store.autocomplete(query: "example").first?.title, "(1) Example Domain")
    }

    func testPrefixMatchRanksAboveMidStringMatch() throws {
        let now = Date()
        try store.recordVisit(url: "https://example.com", title: "Example Homepage", at: now)
        try store.recordVisit(url: "https://another.com/example", title: "Another Site", at: now)

        let results = try store.autocomplete(query: "example", now: now)

        XCTAssertEqual(results.first?.url, "https://example.com",
                        "a match at the start of the host should outrank a match buried in the path")
    }

    func testHigherVisitCountRanksAboveLowerAtEqualRecency() throws {
        let now = Date()
        for _ in 0..<5 {
            try store.recordVisit(url: "https://frequent.example", title: "Frequent", at: now)
        }
        try store.recordVisit(url: "https://rare.example", title: "Rare", at: now)

        let results = try store.autocomplete(query: "example", now: now)
        let urls = results.map(\.url)

        XCTAssertEqual(urls.first, "https://frequent.example")
        XCTAssertTrue(urls.firstIndex(of: "https://frequent.example")! < urls.firstIndex(of: "https://rare.example")!)
    }

    func testRecentVisitRanksAboveOldVisitAtEqualCount() throws {
        let now = Date()
        let fortyDaysAgo = now.addingTimeInterval(-40 * 24 * 3600)
        try store.recordVisit(url: "https://old.example", title: "Old", at: fortyDaysAgo)
        try store.recordVisit(url: "https://new.example", title: "New", at: now)

        let results = try store.autocomplete(query: "example", now: now)

        XCTAssertEqual(results.first?.url, "https://new.example",
                        "a single recent visit should outrank a single stale visit of the same age-independent weight")
    }

    func testRepeatedVisitsRollUpVisitCountAndLatestTitle() throws {
        let t1 = Date()
        let t2 = t1.addingTimeInterval(60)
        try store.recordVisit(url: "https://example.com", title: "First Title", at: t1)
        try store.recordVisit(url: "https://example.com", title: "Second Title", at: t2)

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.visitCount, 2)
        XCTAssertEqual(entries.first?.title, "Second Title")
    }

    func testEmptyQueryReturnsNoSuggestions() throws {
        try store.recordVisit(url: "https://example.com", title: "Example")
        XCTAssertEqual(try store.autocomplete(query: ""), [])
        XCTAssertEqual(try store.autocomplete(query: "   "), [])
    }

    func testDeleteItemRemovesRollupAndVisits() throws {
        try store.recordVisit(url: "https://example.com", title: "Example")
        try store.deleteItem(url: "https://example.com")

        XCTAssertEqual(try store.entries().count, 0)
    }

    func testDeleteRangeRemovesOnlyVisitsInRangeAndDropsEmptyRollups() throws {
        let base = Date()
        try store.recordVisit(url: "https://only-old.example", title: "Old", at: base.addingTimeInterval(-100))
        try store.recordVisit(url: "https://both.example", title: "Both", at: base.addingTimeInterval(-100))
        try store.recordVisit(url: "https://both.example", title: "Both", at: base.addingTimeInterval(1000))

        try store.deleteRange(
            from: base.addingTimeInterval(-200),
            to: base.addingTimeInterval(0)
        )

        let remaining = try store.entries()
        let urls = Set(remaining.map(\.url))
        XCTAssertFalse(urls.contains("https://only-old.example"), "a URL with no visits left in range should be dropped entirely")
        XCTAssertTrue(urls.contains("https://both.example"), "a URL with a visit outside the deleted range should survive")
        XCTAssertEqual(remaining.first(where: { $0.url == "https://both.example" })?.visitCount, 1)
    }

    func testDeleteAllClearsEverything() throws {
        try store.recordVisit(url: "https://a.example", title: "A")
        try store.recordVisit(url: "https://b.example", title: "B")
        try store.deleteAll()

        XCTAssertEqual(try store.entries().count, 0)
    }

    func testMatchingSubstringFilterOnEntries() throws {
        try store.recordVisit(url: "https://swift.org", title: "The Swift Programming Language")
        try store.recordVisit(url: "https://apple.com", title: "Apple")

        let filtered = try store.entries(matching: "swift")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.url, "https://swift.org")
    }

    func testTopFrecentRanksByFrecencyWithNoTextFilter() throws {
        let now = Date()
        for _ in 0..<5 {
            try store.recordVisit(url: "https://frequent.example", title: "Frequent", at: now)
        }
        try store.recordVisit(url: "https://rare.example", title: "Rare", at: now)

        let top = try store.topFrecent(now: now)
        let urls = top.map(\.url)

        XCTAssertEqual(urls.first, "https://frequent.example")
        XCTAssertTrue(urls.contains("https://rare.example"), "topFrecent has no text filter -- every history entry is a candidate")
    }

    func testTopFrecentRespectsLimit() throws {
        let now = Date()
        for i in 0..<20 {
            try store.recordVisit(url: "https://site\(i).example", title: "Site \(i)", at: now)
        }

        XCTAssertEqual(try store.topFrecent(limit: 8, now: now).count, 8)
    }

    func testTopFrecentOnEmptyHistoryReturnsEmpty() throws {
        XCTAssertEqual(try store.topFrecent(), [])
    }

    func testTopFrecentRecentVisitOutranksOldVisitAtEqualCount() throws {
        let now = Date()
        let fortyDaysAgo = now.addingTimeInterval(-40 * 24 * 3600)
        try store.recordVisit(url: "https://old.example", title: "Old", at: fortyDaysAgo)
        try store.recordVisit(url: "https://new.example", title: "New", at: now)

        let top = try store.topFrecent(now: now)
        XCTAssertEqual(top.first?.url, "https://new.example")
    }

    // MARK: - importVisits (browser-ymx's Safari history import)

    func testImportVisitsSumsCountForANewURL() throws {
        let now = Date()
        try store.importVisits([
            (url: "https://imported.example", title: "Imported", visitTime: now.addingTimeInterval(-3600)),
            (url: "https://imported.example", title: "Imported", visitTime: now),
        ])

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.visitCount, 2)
    }

    func testImportVisitsAddsToAnAlreadyExistingURLRatherThanReplacingIt() throws {
        let now = Date()
        try store.recordVisit(url: "https://both.example", title: "Both", at: now.addingTimeInterval(-7200))
        try store.importVisits([
            (url: "https://both.example", title: "Both", visitTime: now.addingTimeInterval(-3600)),
        ])

        let entries = try store.entries()
        XCTAssertEqual(entries.first(where: { $0.url == "https://both.example" })?.visitCount, 2,
                        "one real visit plus one imported visit should sum, not overwrite")
    }

    func testImportVisitsNeverRegressesLastVisitTimeBackward() throws {
        let now = Date()
        try store.recordVisit(url: "https://recent.example", title: "Recent", at: now)
        // An import replaying an *older* visit for a URL this profile has
        // already visited more recently since shouldn't move
        // last_visit_time backward -- frecency ranking would otherwise
        // regress for a URL the user just visited moments ago.
        try store.importVisits([
            (url: "https://recent.example", title: "Recent", visitTime: now.addingTimeInterval(-30 * 24 * 3600)),
        ])

        let entries = try store.entries()
        let entry = entries.first(where: { $0.url == "https://recent.example" })
        XCTAssertEqual(entry?.lastVisitTime.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
    }

    func testImportVisitsFillsInATitleForAURLThatHadNoneYet() throws {
        try store.recordVisit(url: "https://untitled.example", title: nil, at: Date())
        try store.importVisits([
            (url: "https://untitled.example", title: "Now Has A Title", visitTime: Date()),
        ])

        let entries = try store.entries()
        XCTAssertEqual(entries.first(where: { $0.url == "https://untitled.example" })?.title, "Now Has A Title")
    }
}
