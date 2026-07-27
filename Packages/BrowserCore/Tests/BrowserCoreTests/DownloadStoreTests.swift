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
