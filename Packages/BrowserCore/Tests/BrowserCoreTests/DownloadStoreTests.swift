import XCTest
@testable import BrowserCore

final class DownloadStoreTests: XCTestCase {
    private var dir: URL!
    private var store: DownloadStore!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        store = DownloadStore(database: try Database(profileDirectory: dir))
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testCreateStartsInPendingState() throws {
        let id = try store.create(url: "https://example.com/file.zip", suggestedName: "file.zip", destinationPath: "/tmp/file.zip")
        let item = try store.item(id: id)

        XCTAssertEqual(item?.state, .pending)
        XCTAssertEqual(item?.receivedBytes, 0)
        XCTAssertEqual(item?.totalBytes, -1)
        XCTAssertNil(item?.completedAt)
    }

    func testUpdateProgressMovesToInProgress() throws {
        let id = try store.create(url: "https://example.com/file.zip", suggestedName: "file.zip", destinationPath: "/tmp/file.zip")
        try store.updateProgress(id: id, receivedBytes: 512, totalBytes: 1024)

        let item = try store.item(id: id)
        XCTAssertEqual(item?.state, .inProgress)
        XCTAssertEqual(item?.receivedBytes, 512)
        XCTAssertEqual(item?.totalBytes, 1024)
    }

    func testCompletingSetsCompletedAt() throws {
        let id = try store.create(url: "https://example.com/file.zip", suggestedName: "file.zip", destinationPath: "/tmp/file.zip")
        try store.updateState(id: id, state: .completed)

        let item = try store.item(id: id)
        XCTAssertEqual(item?.state, .completed)
        XCTAssertNotNil(item?.completedAt)
    }

    func testFailingDoesNotSetCompletedAt() throws {
        let id = try store.create(url: "https://example.com/file.zip", suggestedName: "file.zip", destinationPath: "/tmp/file.zip")
        try store.updateState(id: id, state: .failed)

        let item = try store.item(id: id)
        XCTAssertEqual(item?.state, .failed)
        XCTAssertNil(item?.completedAt)
    }

    func testAllOrdersNewestFirst() throws {
        let older = try store.create(url: "https://example.com/a", suggestedName: "a", destinationPath: "/tmp/a", at: Date().addingTimeInterval(-100))
        let newer = try store.create(url: "https://example.com/b", suggestedName: "b", destinationPath: "/tmp/b", at: Date())

        let all = try store.all()
        XCTAssertEqual(all.map(\.id), [newer, older])
    }

    /// browser-s24: Chromium auto-retries an interrupted download through the
    /// same CefDownloadItem, so a retry has to land on the row the first
    /// attempt created -- one row per user-visible download, whatever the
    /// engine does behind it.
    func testRestartRewindsTheSameRowRatherThanNeedingANewOne() throws {
        let id = try store.create(url: "https://example.com/file.zip", suggestedName: "file.zip", destinationPath: "/tmp/file.zip")
        try store.updateProgress(id: id, receivedBytes: 900, totalBytes: 1024)

        try store.restart(id: id, destinationPath: "/tmp/file (1).zip")

        let item = try store.item(id: id)
        XCTAssertEqual(item?.state, .pending)
        XCTAssertEqual(item?.receivedBytes, 0)
        XCTAssertEqual(item?.totalBytes, -1)
        // The retry can resolve to a different unique filename than the first
        // attempt did, so the row has to follow the path actually being used.
        XCTAssertEqual(item?.destinationPath, "/tmp/file (1).zip")
        XCTAssertEqual(try store.all().count, 1)
    }

    func testRestartKeepsStartedAtAndClearsCompletedAt() throws {
        let started = Date().addingTimeInterval(-500)
        let id = try store.create(url: "https://example.com/file.zip", suggestedName: "file.zip", destinationPath: "/tmp/file.zip", at: started)
        try store.updateState(id: id, state: .completed)

        try store.restart(id: id, destinationPath: "/tmp/file.zip")

        let item = try store.item(id: id)
        XCTAssertNil(item?.completedAt)
        XCTAssertEqual(item?.startedAt.timeIntervalSince1970 ?? 0, started.timeIntervalSince1970, accuracy: 0.001)
    }

    /// browser-s24: a row left mid-flight by a process that died can never be
    /// finished by anything, so it must not be shown as still downloading
    /// after a relaunch.
    func testReconcileUnfinishedInterruptsOnlyNonTerminalRows() throws {
        let pending = try store.create(url: "https://example.com/a", suggestedName: "a", destinationPath: "/tmp/a")
        let inProgress = try store.create(url: "https://example.com/b", suggestedName: "b", destinationPath: "/tmp/b")
        try store.updateProgress(id: inProgress, receivedBytes: 10, totalBytes: 100)
        let completed = try store.create(url: "https://example.com/c", suggestedName: "c", destinationPath: "/tmp/c")
        try store.updateState(id: completed, state: .completed)
        let cancelled = try store.create(url: "https://example.com/d", suggestedName: "d", destinationPath: "/tmp/d")
        try store.updateState(id: cancelled, state: .cancelled)

        let changed = try store.reconcileUnfinished()

        XCTAssertEqual(changed, 2)
        XCTAssertEqual(try store.item(id: pending)?.state, .interrupted)
        XCTAssertEqual(try store.item(id: inProgress)?.state, .interrupted)
        XCTAssertEqual(try store.item(id: completed)?.state, .completed)
        XCTAssertEqual(try store.item(id: cancelled)?.state, .cancelled)
        // The bytes already received are still the truth about what landed on
        // disk -- reconciling the state must not rewrite them.
        XCTAssertEqual(try store.item(id: inProgress)?.receivedBytes, 10)
    }

    func testReconcileUnfinishedIsANoOpWithNothingInFlight() throws {
        let completed = try store.create(url: "https://example.com/c", suggestedName: "c", destinationPath: "/tmp/c")
        try store.updateState(id: completed, state: .completed)

        XCTAssertEqual(try store.reconcileUnfinished(), 0)
        XCTAssertEqual(try store.item(id: completed)?.state, .completed)
    }

    func testClearCompletedOnlyRemovesCompletedEntries() throws {
        let completed = try store.create(url: "https://example.com/a", suggestedName: "a", destinationPath: "/tmp/a")
        try store.updateState(id: completed, state: .completed)
        let inProgress = try store.create(url: "https://example.com/b", suggestedName: "b", destinationPath: "/tmp/b")
        try store.updateProgress(id: inProgress, receivedBytes: 10, totalBytes: 100)

        try store.clearCompleted()

        let remaining = try store.all()
        XCTAssertEqual(remaining.map(\.id), [inProgress])
    }
}
