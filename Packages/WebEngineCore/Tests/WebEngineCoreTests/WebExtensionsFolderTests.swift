import XCTest
@testable import WebEngineCore

/// Moving a profile's extensions out of Chromium's `Extensions/`, and
/// telling when a store package has to be fetched again.
final class WebExtensionsFolderTests: XCTestCase {
    private var profile: URL!
    private let store = String(repeating: "a", count: 32)
    private let dev = String(repeating: "b", count: 32)
    private let chromiums = String(repeating: "c", count: 32)

    override func setUpWithError() throws {
        profile = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: profile)
    }

    private var old: URL { profile.appendingPathComponent("Extensions", isDirectory: true) }
    private var new: URL { profile.appendingPathComponent("WebExtensions", isDirectory: true) }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func list(_ ids: [(String, InstalledWebExtension.Source)], in folder: URL, name: String = "Old") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let records = ids.map { InstalledWebExtension(id: $0.0, source: $0.1, name: name, version: "1", unpackedPath: $0.1 == .unpacked ? "/dev" : nil, grants: []) }
        try InstalledWebExtensionList(extensions: records).save(to: folder.appendingPathComponent("installed.json"))
    }

    private func names(_ folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// An earlier version's layout, with something of Chromium's beside it.
    private func makeOldLayout() throws {
        try list([(store, .webStore), (dev, .unpacked)], in: old)
        try write("{}", "\(store)/manifest.json", in: old)
        try write("{}", "webkit/\(store)/manifest.json", in: old)
        try write("{}", "webkit/\(store).json", in: old)
        try write("x", ".staging-\(store)-1/manifest.json", in: old)
        try write("chromium's", "\(chromiums)/1.0_0/manifest.json", in: old)
        try write("chromium's", "Temp/x", in: old)
    }

    func testOursMovesAndChromiumsStays() throws {
        try makeOldLayout()
        let moved = try WebExtensionsFolder.moveFromChromiumFolder(inProfile: profile)
        XCTAssertEqual(Set(moved), [store, "webkit", ".staging-\(store)-1", "installed.json"])
        XCTAssertEqual(names(new), [store, "webkit", ".staging-\(store)-1", "installed.json"])
        XCTAssertEqual(names(old), [chromiums, "Temp"], "only Chromium's things are left")
        XCTAssertEqual(InstalledWebExtensionList.load(from: new.appendingPathComponent("installed.json")).extensions.map(\.id), [store, dev])
        XCTAssertEqual(WebExtensionsFolder.directory(inProfile: profile), new)
    }

    func testNothingToMoveWithoutAList() throws {
        try write("chromium's", "\(chromiums)/1.0_0/manifest.json", in: old)
        XCTAssertEqual(try WebExtensionsFolder.moveFromChromiumFolder(inProfile: profile), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "a profile with nothing of ours gets no folder")
        XCTAssertEqual(names(old), [chromiums])
    }

    /// The case Chromium's collector leaves: the list survives, the
    /// packages do not.
    func testAListWhosePackagesWereDeletedStillMoves() throws {
        try list([(store, .webStore)], in: old)
        XCTAssertEqual(try WebExtensionsFolder.moveFromChromiumFolder(inProfile: profile), ["installed.json"])
        XCTAssertEqual(names(new), ["installed.json"])
    }

    func testANewerListIsNeverOverwrittenAndTheOldOneGoes() throws {
        try makeOldLayout()
        try list([(store, .webStore)], in: new, name: "Newer")
        try write("newer", "\(store)/manifest.json", in: new)
        _ = try WebExtensionsFolder.moveFromChromiumFolder(inProfile: profile)
        XCTAssertEqual(InstalledWebExtensionList.load(from: new.appendingPathComponent("installed.json")).extensions.first?.name, "Newer")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("\(store)/manifest.json"), encoding: .utf8), "newer")
        XCTAssertEqual(names(old), [chromiums, "Temp"], "the older copies of ours are gone")
    }

    /// A move stopped part-way -- here, after the package went but before
    /// the list did -- is finished by the next call, with nothing lost.
    func testAnInterruptedMoveIsFinishedNextTime() throws {
        try makeOldLayout()
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old.appendingPathComponent(store), to: new.appendingPathComponent(store))
        let moved = try WebExtensionsFolder.moveFromChromiumFolder(inProfile: profile)
        XCTAssertFalse(moved.contains(store))
        XCTAssertEqual(names(new), [store, "webkit", ".staging-\(store)-1", "installed.json"])
        XCTAssertEqual(try WebExtensionsFolder.moveFromChromiumFolder(inProfile: profile), [], "a finished move does nothing")
    }

    func testPreparedMovesAndAnswersTheNewFolder() throws {
        try makeOldLayout()
        var logged: [String] = []
        XCTAssertEqual(WebExtensionsFolder.prepared(inProfile: profile) { logged.append($0) }, new)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("installed.json").path))
    }

    private func state(_ record: InstalledWebExtension) -> WebExtensionsFolder.PackageState {
        WebExtensionsFolder.packageState(of: record, packageFolder: new.appendingPathComponent(record.id, isDirectory: true), in: new)
    }

    private func makePackage() throws -> (InstalledWebExtension, URL) {
        let folder = new.appendingPathComponent(store, isDirectory: true)
        try write(#"{"name":"S","version":"1"}"#, "manifest.json", in: folder)
        try write("worker", "js/background.js", in: folder)
        try write("{}", "_locales/en/messages.json", in: folder)
        return (InstalledWebExtension(id: store, source: .webStore, name: "S", version: "1", grants: []), folder)
    }

    func testAPackageIsMissingUnverifiedOrWhole() throws {
        let record = InstalledWebExtension(id: store, source: .webStore, name: "S", version: "1", grants: [])
        XCTAssertEqual(state(record), .missing)
        let (_, folder) = try makePackage()
        XCTAssertEqual(state(record), .unverified, "no record yet")
        try WebExtensionsFolder.recordContents(of: folder, id: store, in: new)
        XCTAssertEqual(state(record), .whole)
        WebExtensionsFolder.forgetContents(id: store, in: new)
        XCTAssertEqual(state(record), .unverified)
    }

    /// What Chromium's collector does to a folder for an id it knows: the
    /// subfolders go and `manifest.json` stays.
    func testAPackageWithItsSubfoldersDeletedIsDamaged() throws {
        let (record, folder) = try makePackage()
        try WebExtensionsFolder.recordContents(of: folder, id: store, in: new)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("js"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("_locales"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(state(record), .damaged)
    }

    func testAChangedFileIsDamaged() throws {
        let (record, folder) = try makePackage()
        try WebExtensionsFolder.recordContents(of: folder, id: store, in: new)
        try write("work", "js/background.js", in: folder)
        XCTAssertEqual(state(record), .damaged)
    }

    func testADevelopersFolderIsNeverJudged() {
        let unpacked = InstalledWebExtension(id: dev, source: .unpacked, name: "D", version: "1", unpackedPath: "/missing", grants: [])
        XCTAssertEqual(state(unpacked), .whole, "a developer's folder is theirs to restore")
    }
}
