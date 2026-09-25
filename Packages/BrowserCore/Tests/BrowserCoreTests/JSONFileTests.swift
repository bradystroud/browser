import XCTest
@testable import BrowserCore

final class JSONFileTests: XCTestCase {
    private struct Settings: Codable, Equatable {
        var enabled: Bool
    }

    private var dir: URL!
    private var file: JSONFile<Settings>!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
        file = JSONFile(url: dir.appendingPathComponent("nested/settings.json"))
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testMissingFileReturnsDefaultAndCreatesNothing() {
        XCTAssertEqual(file.load(default: Settings(enabled: true)), Settings(enabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSaveCreatesParentDirectoryAndRoundTrips() {
        file.save(Settings(enabled: false))
        XCTAssertEqual(file.load(default: Settings(enabled: true)), Settings(enabled: false))
    }

    func testUndecodableFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file.url)

        XCTAssertEqual(file.load(default: Settings(enabled: true)), Settings(enabled: true))

        let corrupt = file.url.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: corrupt, encoding: .utf8), "{ not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))

        file.save(Settings(enabled: false))
        XCTAssertEqual(try String(contentsOf: corrupt, encoding: .utf8), "{ not json",
                       "a later save must not touch the preserved copy")
    }
}
