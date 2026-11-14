import XCTest
@testable import WebEngineCore

/// The store package's folder stays as it unpacked; the WebKit engine loads
/// a prepared copy derived from it; and a folder the layer was once written
/// into comes back to the package.
final class PreparedExtensionCopyTests: XCTestCase {
    private var root: URL!
    private let id = "pejdijmoenmkgeppbflobdenhhabjlaj"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var pristine: URL { root.appendingPathComponent(id, isDirectory: true) }
    private var copies: URL { root.appendingPathComponent("webkit", isDirectory: true) }

    private func write(_ text: String, _ path: String, in folder: URL? = nil) throws {
        let url = (folder ?? pristine).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let base = folder.resolvingSymlinksInPath().path
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    private func json(_ data: Data?) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? NSDictionary)
    }

    /// Shaped like iCloud Passwords, with the manifest written the way a
    /// store package writes it (not the layer's sorted layout).
    private func makePackage(background: String = #""service_worker": "background.js""#) throws {
        try write("""
        {
            "name": "Fixture", "version": "1.0", "manifest_version": 3,
            "permissions": ["privacy", "nativeMessaging"],
            "background": { \(background) },
            "options_ui": { "page": "settings.html" }
        }
        """, "manifest.json")
        try write("self.ran = true;\n", "background.js")
        try write("<html><head><SCRIPT src=\"settings.js\"></SCRIPT></head></html>\n", "settings.html")
        try write("<html><body>no script</body></html>\n", "about.html")
        try write("{\"x\":{\"message\":\"y\"}}", "_locales/en/messages.json")
    }

    // MARK: - Reversal

    private func assertRoundTrip(file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try snapshot(pristine)
        try ChromeExtensionCompatibility.prepare(folder: pristine)
        XCTAssertTrue(ChromeExtensionCompatibility.isPrepared(folder: pristine), file: file, line: line)
        try ChromeExtensionCompatibility.unprepare(folder: pristine)
        let after = try snapshot(pristine)
        XCTAssertFalse(ChromeExtensionCompatibility.isPrepared(folder: pristine), file: file, line: line)
        XCTAssertEqual(Set(after.keys), Set(before.keys), file: file, line: line)
        for (path, data) in before where path != "manifest.json" {
            XCTAssertEqual(after[path], data, "\(path) comes back byte for byte", file: file, line: line)
        }
        XCTAssertEqual(try json(after["manifest.json"]), try json(before["manifest.json"]), "same content", file: file, line: line)
    }

    func testClassicWorkerRoundTrips() throws {
        try makePackage()
        try assertRoundTrip()
    }

    func testModuleWorkerInASubfolderRoundTrips() throws {
        try makePackage(background: #""service_worker": "js/sw.js", "type": "module""#)
        try write("", "js/sw.js")
        try assertRoundTrip()
    }

    func testBackgroundScriptsAndPageRoundTrip() throws {
        try makePackage(background: #""scripts": ["a.js", "b.js"]"#)
        try assertRoundTrip()
        try FileManager.default.removeItem(at: pristine)
        try makePackage(background: #""page": "bg.html""#)
        try write("<script src=\"bg.js\"></script>", "bg.html")
        try assertRoundTrip()
    }

    func testAWrapperTheLayerDidNotWriteIsRefused() throws {
        try makePackage(background: #""service_worker": "__browser_background.js""#)
        try write("importScripts('mine.js');\n", "__browser_background.js")
        XCTAssertThrowsError(try ChromeExtensionCompatibility.unprepare(folder: pristine)) {
            XCTAssertEqual($0 as? ChromeExtensionCompatibility.ReversalError, .unreadableWrapper)
        }
        XCTAssertNil(ChromeExtensionCompatibility.originalWorker(in: ChromeExtensionCompatibility.workerHeader + "importScripts(\"/x.js\");"))
    }

    func testRestorePristineSwapsInTheReversedFolder() throws {
        try makePackage()
        let package = try snapshot(pristine)
        try ChromeExtensionCompatibility.prepare(folder: pristine)
        XCTAssertTrue(try PreparedExtensionCopy.restorePristine(pristine))
        XCTAssertEqual(try snapshot(pristine).filter { $0.key != "manifest.json" }, package.filter { $0.key != "manifest.json" })
        XCTAssertFalse(try PreparedExtensionCopy.restorePristine(pristine), "a package folder needs nothing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [id], "no staging or set-aside folder is left")
    }

    // MARK: - The prepared copy

    func testCopyIsPreparedAndThePackageIsNotTouched() throws {
        try makePackage()
        let package = try snapshot(pristine)
        let copy = try XCTUnwrap(try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id))
        XCTAssertEqual(copy, copies.appendingPathComponent(id, isDirectory: true))
        XCTAssertEqual(try snapshot(pristine), package)
        XCTAssertTrue(ChromeExtensionCompatibility.isPrepared(folder: copy))
        XCTAssertEqual(try json(snapshot(copy)["manifest.json"])["background"] as? NSDictionary, ["service_worker": "__browser_background.js"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: copies.path)), [id, id + ".json"])
    }

    func testCopyIsReusedUntilThePackageChanges() throws {
        try makePackage()
        let copy = try XCTUnwrap(try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id))
        try write("left by the first build", "marker", in: copy)
        _ = try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("marker").path), "an up-to-date copy is not rebuilt")

        try write("self.ran = 'version 2';\n", "background.js")
        _ = try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("marker").path), "a changed package is copied again")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("background.js"), encoding: .utf8), "self.ran = 'version 2';\n")
    }

    func testAStampFromAnotherLayerRebuildsTheCopy() throws {
        try makePackage()
        let copy = try XCTUnwrap(try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id))
        try write("x", "marker", in: copy)
        try Data(#"{"fingerprint":"from an older shim"}"#.utf8).write(to: copies.appendingPathComponent(id + ".json"))
        _ = try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("marker").path))
    }

    func testAPackageThatNeedsNoLayerGetsNoCopyAndLosesAnOldOne() throws {
        try makePackage()
        _ = try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id)
        try write(#"{"name": "Plain", "version": "2", "manifest_version": 3, "permissions": ["storage"]}"#, "manifest.json")
        XCTAssertNil(try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), [])
    }

    func testAFailedBuildLeavesNoHalfCopy() throws {
        try makePackage()
        try write("// the extension's own\n", "__browser_background.js")
        XCTAssertThrowsError(try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), [], "no copy, no stamp, no staging")
    }

    func testRemoveDeletesCopyAndStamp() throws {
        try makePackage()
        _ = try PreparedExtensionCopy.ensure(pristine: pristine, copies: copies, id: id)
        PreparedExtensionCopy.remove(id: id, in: copies)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pristine.appendingPathComponent("manifest.json").path))
    }
}
