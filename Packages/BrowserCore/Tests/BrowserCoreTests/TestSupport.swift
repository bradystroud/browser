import Foundation

enum TestSupport {
    static func makeTempProfileDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
