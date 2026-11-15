import XCTest
@testable import WebEngineCore

/// The CEF copy made from a folder that carries WebKit's compatibility layer
/// (`ChromeExtensionCompatibility`, written by the real code here) is the
/// copy made from the pristine folder: the preparer takes the layer out
/// exactly, whatever form the source is in.
final class CEFExtensionLayerRoundTripTests: XCTestCase {
    private let fixtureID = "pgmnddkfhcbihfijmfgancppilgkimei"
    private var base: URL!
    private var key: Data!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cef-layer-\(UUID().uuidString)", isDirectory: true)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture-hello", withExtension: "crx", subdirectory: "Fixtures"))
        key = try Crx3.verifiedPackage(Data(contentsOf: url), expectedID: fixtureID).publicKey
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func files(in folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path))
        while let path = walker.nextObject() as? String {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { out[path] = try Data(contentsOf: folder.appendingPathComponent(path)) }
        }
        return out
    }

    private func makeSource(_ name: String, workerPath: String) throws -> URL {
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try write(#"{"manifest_version":3,"name":"Layered","version":"1.2","permissions":["privacy","storage"],"background":{"service_worker":"\#(workerPath)"},"action":{"default_popup":"popup.html"}}"#,
                  "manifest.json", in: folder)
        try write("chrome.runtime.onInstalled.addListener(() => {});\n", workerPath, in: folder)
        try write("<!doctype html><html><head><title>p</title><script src=\"popup.js\"></script></head><body></body></html>", "popup.html", in: folder)
        try write("document.title = 'popup';\n", "popup.js", in: folder)
        return folder
    }

    private func assertRoundTrip(workerPath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let pristine = try makeSource("pristine-\(workerPath.hashValue)", workerPath: workerPath)
        let layered = try makeSource("layered-\(workerPath.hashValue)", workerPath: workerPath)
        let written = try ChromeExtensionCompatibility.prepare(folder: layered)
        XCTAssertFalse(written.isEmpty, "the layer was not written", file: file, line: line)

        let token = "0123456789abcdef0123456789abcdef"
        let fromPristine = base.appendingPathComponent("out-a-\(workerPath.hashValue)/copy")
        let fromLayered = base.appendingPathComponent("out-b-\(workerPath.hashValue)/copy")
        try CEFExtensionPreparer.prepare(source: pristine, extensionID: fixtureID, publicKey: key, destination: fromPristine, token: token)
        let prepared = try CEFExtensionPreparer.prepare(source: layered, extensionID: fixtureID, publicKey: key, destination: fromLayered, token: token)
        XCTAssertTrue(prepared.removedWebKitLayer, file: file, line: line)

        let a = try files(in: fromPristine), b = try files(in: fromLayered)
        XCTAssertEqual(Set(a.keys), Set(b.keys), file: file, line: line)
        XCTAssertFalse(b.keys.contains { $0.contains("__browser_") }, file: file, line: line)
        for (path, data) in a where path != "manifest.json" {
            XCTAssertEqual(data, b[path], path, file: file, line: line)
        }
        let manifestA = try JSONSerialization.jsonObject(with: XCTUnwrap(a["manifest.json"])) as? NSDictionary
        let manifestB = try JSONSerialization.jsonObject(with: XCTUnwrap(b["manifest.json"])) as? NSDictionary
        XCTAssertEqual(manifestA, manifestB, file: file, line: line)
    }

    func testRootWorker() throws { try assertRoundTrip(workerPath: "sw.js") }
    func testWorkerInASubfolder() throws { try assertRoundTrip(workerPath: "js/sw.js") }
}
