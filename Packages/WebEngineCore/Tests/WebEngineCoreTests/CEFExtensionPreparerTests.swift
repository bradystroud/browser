import XCTest
@testable import WebEngineCore

final class CEFExtensionPreparerTests: XCTestCase {
    private let fixtureID = "pgmnddkfhcbihfijmfgancppilgkimei"
    private var base: URL!
    private var source: URL!
    private var destination: URL!
    private var key: Data!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cef-prep-\(UUID().uuidString)", isDirectory: true)
        source = base.appendingPathComponent("source", isDirectory: true)
        destination = base.appendingPathComponent("out/\(fixtureID)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture-hello", withExtension: "crx", subdirectory: "Fixtures"))
        key = try XCTUnwrap(Crx3.verifiedPackage(Data(contentsOf: url), expectedID: fixtureID)).publicKey
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func write(_ text: String, to path: String, in folder: URL? = nil) throws {
        let url = (folder ?? source).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
    }

    private func manifest(in folder: URL? = nil) throws -> [String: Any] {
        let url = (folder ?? destination).appendingPathComponent("manifest.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        let root = folder.resolvingSymlinksInPath().path
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files[String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    private func makeExtension(worker: String = #""service_worker": "background.js""#, extra: String = "") throws {
        try write("""
        {
            "manifest_version": 3, "name": "Fixture", "version": "1.0",
            "permissions": ["storage", "tabs"],
            "host_permissions": ["https://*.example.com/*"],
            \(worker.isEmpty ? "" : "\"background\": { \(worker) },")
            \(extra)
            "action": { "default_popup": "popup.html" }
        }
        """.replacingOccurrences(of: ",\n    \n}", with: "\n}"), to: "manifest.json")
        try write("chrome.runtime.onInstalled.addListener(() => {});\n", to: "background.js")
        try write("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body><script src=\"popup.js\"></script></body></html>\n", to: "popup.html")
        try write("console.log('popup');\n", to: "popup.js")
    }

    private func prepare() throws -> PreparedCEFExtension {
        try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination)
    }

    private var workerName: String { CEFExtensionShim.workerFileName(storeVersion: "1.0") }

    private var shimTag: String { "<script src=\"chrome-extension://\(fixtureID)/\(CEFExtensionShim.fileName)\"></script>" }

    // MARK: - Manifest

    func testClassicWorkerIsWrappedAndTheManifestGetsKeyAndBridgePermission() throws {
        try makeExtension()
        let result = try prepare()
        let m = try manifest()
        XCTAssertEqual((m["background"] as? [String: Any])?["service_worker"] as? String, workerName)
        XCTAssertEqual(m["key"] as? String, key.base64EncodedString())
        XCTAssertEqual(m["host_permissions"] as? [String], ["https://*.example.com/*", CEFExtensionShim.bridgeHostPermission])
        XCTAssertEqual(try read(workerName),
                       "// Written by the browser: runs the CEF shim ahead of the extension's own worker.\nimportScripts(\"/\(CEFExtensionShim.fileName)\", \"/background.js\");\n")
        XCTAssertEqual(try read("background.js"), "chrome.runtime.onInstalled.addListener(() => {});\n", "the extension's own code is untouched")
        XCTAssertEqual(try read(CEFExtensionShim.fileName),
                       CEFExtensionShim.fileContents(storeVersion: "1.0", preparedVersion: "1.0.\(CEFExtensionShim.version)", addedVersionName: true, token: result.token))
        XCTAssertTrue(try read(CEFExtensionShim.fileName).hasPrefix(#"globalThis[Symbol.for('brw.cefInfo')] = {"addedVersionName":true,"preparedVersion":"1.0.\#(CEFExtensionShim.version)","storeVersion":"1.0","token":"\#(result.token)"};"# + "\n"))
        XCTAssertEqual(result.token.count, 32)
        XCTAssertEqual(result.version, "1.0.\(CEFExtensionShim.version)")
        XCTAssertEqual(result.workerFile, workerName)
        XCTAssertEqual(result.pages, ["popup.html"])
        XCTAssertFalse(result.removedWebKitLayer)
    }

    func testModuleWorkerIsWrappedWithImports() throws {
        try makeExtension(worker: #""service_worker": "/src/bg.js", "type": "module""#)
        try write("export {};", to: "src/bg.js")
        _ = try prepare()
        XCTAssertEqual(try read(CEFExtensionShim.workerPath(original: "src/bg.js", storeVersion: "1.0")),
                       "// Written by the browser: runs the CEF shim ahead of the extension's own worker.\nimport \"/\(CEFExtensionShim.fileName)\";\nimport \"/src/bg.js\";\n")
        XCTAssertEqual((try manifest()["background"] as? [String: Any])?["type"] as? String, "module")
    }

    func testManifestWithNoBackgroundStillGetsKeyShimAndPermission() throws {
        try makeExtension(worker: "")
        let result = try prepare()
        let m = try manifest()
        XCTAssertNil(m["background"])
        XCTAssertNil(result.workerFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(workerName).path))
        XCTAssertTrue((m["host_permissions"] as? [String])?.contains(CEFExtensionShim.bridgeHostPermission) == true)
        XCTAssertEqual(m["key"] as? String, key.base64EncodedString())
        XCTAssertTrue(try read("popup.html").contains(shimTag))
    }

    func testHostPermissionsAreCreatedWhenTheManifestHasNone() throws {
        try write(#"{"manifest_version": 3, "name": "N", "version": "1"}"#, to: "manifest.json")
        _ = try prepare()
        XCTAssertEqual(try manifest()["host_permissions"] as? [String], [CEFExtensionShim.bridgeHostPermission])
    }

    func testBridgeIsAllowedThroughAnExtensionsOwnContentSecurityPolicy() throws {
        XCTAssertEqual(CEFExtensionPreparer.allowingBridge(inPolicy: "script-src 'self'; object-src 'self'"),
                       "script-src 'self'; object-src 'self';", "a policy that restricts no fetch is left as it is")
        XCTAssertEqual(CEFExtensionPreparer.allowingBridge(inPolicy: "script-src 'self'; connect-src 'self' https://api.example.com"),
                       "script-src 'self'; connect-src 'self' https://api.example.com https://extension-bridge.browser.invalid;")
        XCTAssertEqual(CEFExtensionPreparer.allowingBridge(inPolicy: "default-src 'self'; script-src 'self'"),
                       "default-src 'self'; script-src 'self'; connect-src 'self' https://extension-bridge.browser.invalid;")
        XCTAssertEqual(CEFExtensionPreparer.allowingBridge(inPolicy: "connect-src 'none'"),
                       "connect-src https://extension-bridge.browser.invalid;")
        XCTAssertEqual(CEFExtensionPreparer.allowingBridge(inPolicy: "connect-src *"), "connect-src *;")
        try makeExtension(extra: #""content_security_policy": { "extension_pages": "script-src 'self'; connect-src 'self'" },"#)
        _ = try prepare()
        let csp = (try manifest()["content_security_policy"] as? [String: Any])?["extension_pages"] as? String
        XCTAssertEqual(csp, "script-src 'self'; connect-src 'self' https://extension-bridge.browser.invalid;")
    }

    func testPlainStoreManifestWithCommentsAndBOMParses() throws {
        try write("\u{FEFF}// store comment\n{\"manifest_version\": 3, \"name\": \"N\", \"version\": \"1\"}", to: "manifest.json")
        _ = try prepare()
        XCTAssertEqual(try manifest()["name"] as? String, "N")
    }

    // MARK: - Version

    func testWorkerPathAndManifestVersionChangeTogetherForEitherReason() {
        func pair(_ store: String, _ shim: Int, _ rev: Int? = nil) -> (String, String?) {
            (CEFExtensionShim.workerFileName(storeVersion: store, shimVersion: shim, revision: rev),
             CEFExtensionShim.preparedVersion(storeVersion: store, shimVersion: shim, revision: rev))
        }
        for store in ["1", "1.0", "1.0.1", "1.2.3.4"] {
            for rev in 0...30 {
                XCTAssertNotEqual(pair(store, 1, rev).0, pair(store, 1, rev + 1).0, "revision change alone, \(store)")
                XCTAssertNotEqual(pair(store, 1, rev).1, pair(store, 1, rev + 1).1, "revision change alone, \(store)")
            }
            XCTAssertNotEqual(pair(store, 1, 0).0, pair(store, 1).0, "a revision against none")
            XCTAssertNotEqual(pair(store, 1, 5).0, pair(store, 2, 5).0)
            XCTAssertNotEqual(pair(store, 1, 5).1, pair(store, 2, 5).1)
            XCTAssertNotEqual(pair(store, 1, 5).0, pair("9.9", 1, 5).0)
        }
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1", shimVersion: 1, revision: 7), "1.1.8")
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.0", shimVersion: 1, revision: 7), "1.0.1.8")
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.0.2", shimVersion: 1, revision: 7), "1.0.2.9")
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.0.2.3", shimVersion: 1, revision: 7), "1.0.2.12")
        XCTAssertNil(CEFExtensionShim.preparedVersion(storeVersion: "1.0.2.65530", shimVersion: 1, revision: 7))
        XCTAssertNil(CEFExtensionShim.preparedVersion(storeVersion: "1.0", shimVersion: 1, revision: -1))
        XCTAssertEqual(CEFExtensionShim.workerFileName(storeVersion: "1.0", revision: 12), "brw-background.v\(CEFExtensionShim.version)-1.0-r12.js")
        let stores = ["1.0", "1.0.1", "2.3.4", "1.2.3.4", "1.2.3.5", "7"]
        for a in stores {
            for b in stores where a != b {
                for shim in 1...20 {
                    XCTAssertNotEqual(pair(a, shim).0, pair(b, shim).0, "store change alone, \(a) -> \(b)")
                    XCTAssertNotEqual(pair(a, shim).1, pair(b, shim).1, "store change alone, \(a) -> \(b)")
                }
            }
            for shim in 1...50 {
                XCTAssertNotEqual(pair(a, shim).0, pair(a, shim + 1).0, "shim change alone")
                XCTAssertNotEqual(pair(a, shim).1, pair(a, shim + 1).1, "shim change alone")
            }
        }
        for shim in 1...20 {
            XCTAssertNotEqual(pair("1.0", shim).0, pair("1.1", shim + 1).0, "both")
            XCTAssertNotEqual(pair("1.0", shim).1, pair("1.1", shim + 1).1, "both")
        }
        XCTAssertEqual(CEFExtensionShim.workerFileName(storeVersion: "1.0"), "brw-background.v\(CEFExtensionShim.version)-1.0.js")
        XCTAssertFalse(CEFExtensionShim.workerFileName(storeVersion: "../x/y").contains("/"))
    }

    func testAContentRevisionRenamesTheWorkerAndRaisesTheVersionAndRejectsOutOfRange() throws {
        try makeExtension()
        func run(_ revision: Int?) throws -> (String?, String?) {
            _ = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination, contentRevision: revision)
            let m = try manifest()
            return ((m["background"] as? [String: Any])?["service_worker"] as? String, m["version"] as? String)
        }
        let none = try run(nil), one = try run(1), two = try run(2)
        XCTAssertEqual(Set([none.0, one.0, two.0].compactMap { $0 }).count, 3)
        XCTAssertEqual(Set([none.1, one.1, two.1].compactMap { $0 }).count, 3)
        XCTAssertEqual(two.1, "1.0.\(CEFExtensionShim.version).3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(two.0!).path))
        XCTAssertFalse(two.0!.hasPrefix("_"))
        for bad in [-1, 65536] {
            XCTAssertThrowsError(try run(bad)) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .invalidRevision(bad)) }
        }
    }

    func testAStoreUpdateRenamesTheWorkerAndRaisesTheVersion() throws {
        try makeExtension()
        _ = try prepare()
        let before = try manifest()
        try write(try String(contentsOf: source.appendingPathComponent("manifest.json")).replacingOccurrences(of: "\"1.0\"", with: "\"1.1\""), to: "manifest.json")
        _ = try prepare()
        let after = try manifest()
        XCTAssertNotEqual((before["background"] as? [String: Any])?["service_worker"] as? String, (after["background"] as? [String: Any])?["service_worker"] as? String)
        XCTAssertNotEqual(before["version"] as? String, after["version"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(workerName).path), "the old wrapper is gone with the old copy")
    }

    func testAVersionThatCollidesWithThePreviousCopyIsRefused() throws {
        try write(#"{"manifest_version": 3, "name": "N", "version": "1.0.0.1", "background": {"service_worker": "b.js"}}"#, to: "manifest.json")
        try write("1", to: "b.js")
        let same = "1.0.0.\(1 + CEFExtensionShim.version)"
        XCTAssertThrowsError(try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination,
                                                              previous: PreviousCEFCopy(version: same, workerFile: "brw-background.v99-1.0.0.1.js"))) {
            XCTAssertEqual($0 as? CEFExtensionPreparationError, .versionCollision(same))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let result = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination,
                                                      previous: PreviousCEFCopy(version: same, workerFile: CEFExtensionShim.workerPath(original: "b.js", storeVersion: "1.0.0.1")))
        XCTAssertEqual(result.version, same, "the same copy again is not a collision")
        _ = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination,
                                             previous: PreviousCEFCopy(version: "9.9", workerFile: "x.js"))
    }

    func testThePreparedManifestAsksForNothingThatCoversFileUrls() throws {
        try write("""
        {"manifest_version": 3, "name": "N", "version": "1",
         "host_permissions": ["<all_urls>", "file:///Users/*"],
         "optional_host_permissions": ["file:///*", "https://*.a.example/*"],
         "content_scripts": [{"matches": ["<all_urls>"], "exclude_matches": ["file:///x/*"], "js": ["c.js"]},
                             {"matches": ["file:///*"], "js": ["d.js"]}, {"matches": ["*://*/*"], "js": ["e.js"]}],
         "web_accessible_resources": [{"resources": ["a.png"], "matches": ["<all_urls>"]}, {"resources": ["b.png"], "matches": ["file:///*"]},
                                      {"resources": ["c.png"], "matches": ["file:///*"], "extension_ids": ["abc"]}],
         "externally_connectable": {"matches": ["file:///*"], "ids": ["*"]}}
        """, to: "manifest.json")
        _ = try prepare()
        let m = try manifest()
        XCTAssertEqual(m["host_permissions"] as? [String], ["http://*/*", "https://*/*", CEFExtensionShim.bridgeHostPermission])
        XCTAssertEqual(m["optional_host_permissions"] as? [String], ["https://*.a.example/*"])
        let scripts = try XCTUnwrap(m["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.map { $0["matches"] as? [String] }, [["http://*/*", "https://*/*"], ["*://*/*"]], "a script with only file: patterns is gone")
        XCTAssertEqual(scripts[0]["exclude_matches"] as? [String], ["file:///x/*"], "excludes are left as they are")
        let resources = try XCTUnwrap(m["web_accessible_resources"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 2)
        XCTAssertEqual(resources[0]["matches"] as? [String], ["http://*/*", "https://*/*"])
        XCTAssertNil(resources[1]["matches"])
        XCTAssertEqual(resources[1]["extension_ids"] as? [String], ["abc"])
        let connectable = try XCTUnwrap(m["externally_connectable"] as? [String: Any])
        XCTAssertNil(connectable["matches"])
        XCTAssertEqual(connectable["ids"] as? [String], ["*"])
        XCTAssertFalse(String(decoding: try Data(contentsOf: destination.appendingPathComponent("manifest.json")), as: UTF8.self).contains("<all_urls>"))
    }

    func testRevisionZeroDiffersFromNoRevisionInChromesEyes() {
        for store in ["1", "1.0", "1.0.1", "1.2.3.4"] {
            XCTAssertNotEqual(CEFExtensionShim.preparedVersion(storeVersion: store, shimVersion: 1, revision: 0),
                              CEFExtensionShim.preparedVersion(storeVersion: store, shimVersion: 1))
        }
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "65535.65535.65535", shimVersion: 2), "65535.65535.65535.2", "full parts are fine ahead of the added one")
        XCTAssertNotEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.0", shimVersion: 2, revision: 2),
                          CEFExtensionShim.preparedVersion(storeVersion: "1.0.1", shimVersion: 2, revision: 1))
    }

    func testWorkersInSubfoldersKeepTheirBaseForRelativePaths() throws {
        for module in [false, true] {
            try? FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try makeExtension(worker: #""service_worker": "js/sw.js"\#(module ? ", \"type\": \"module\"" : "")"#)
            try write("importScripts('util.js');", to: "js/sw.js")
            let result = try prepare()
            let wrapper = CEFExtensionShim.workerPath(original: "js/sw.js", storeVersion: "1.0")
            XCTAssertEqual(wrapper, "js/" + CEFExtensionShim.workerFileName(storeVersion: "1.0"))
            XCTAssertEqual(result.workerFile, wrapper)
            XCTAssertEqual((try manifest()["background"] as? [String: Any])?["service_worker"] as? String, wrapper)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(CEFExtensionShim.workerFileName(storeVersion: "1.0")).path), "not at the root")
            let text = try read(wrapper)
            XCTAssertTrue(text.contains("\"/\(CEFExtensionShim.fileName)\""), "the shim by root path")
            XCTAssertTrue(text.contains("\"/js/sw.js\""), "the original by root path")
            XCTAssertEqual(text.contains("importScripts"), !module)
            XCTAssertEqual(try read("js/sw.js"), "importScripts('util.js');")
        }
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "background": {"service_worker": "./a/b/c.js"}}"#, to: "manifest.json")
        try write("1", to: "a/b/c.js")
        _ = try prepare()
        XCTAssertEqual((try manifest()["background"] as? [String: Any])?["service_worker"] as? String, "a/b/" + CEFExtensionShim.workerFileName(storeVersion: "1"), "./ and / prefixes are dropped")
    }

    func testPreparingTwiceDiffersOnlyInTheTokenUnlessItIsGiven() throws {
        try makeExtension()
        let first = try prepare()
        let a = try snapshot(destination)
        let second = try prepare()
        let b = try snapshot(destination)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(Set(a.keys), Set(b.keys))
        for (name, data) in a where name != CEFExtensionShim.fileName { XCTAssertEqual(b[name], data, name) }
        XCTAssertNotEqual(a[CEFExtensionShim.fileName], b[CEFExtensionShim.fileName])
        XCTAssertEqual(String(decoding: a[CEFExtensionShim.fileName]!, as: UTF8.self).components(separatedBy: "\n").dropFirst(),
                       String(decoding: b[CEFExtensionShim.fileName]!, as: UTF8.self).components(separatedBy: "\n").dropFirst(), "only the first line")
        _ = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination, token: first.token)
        XCTAssertEqual(try snapshot(destination), a, "with the token given, the bytes are the same")
    }

    func testPreparedVersionShapes() {
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.0", shimVersion: 3), "1.0.3")
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.2.3", shimVersion: 3), "1.2.3.3")
        XCTAssertEqual(CEFExtensionShim.preparedVersion(storeVersion: "1.2.3.4", shimVersion: 3), "1.2.3.7")
        XCTAssertNil(CEFExtensionShim.preparedVersion(storeVersion: "1.2.3.65535", shimVersion: 1), "does not fit")
        for bad in ["", "1.", "1.x", "01.2", "1.2.3.4.5", "70000", "-1", "1-beta"] {
            XCTAssertNil(CEFExtensionShim.preparedVersion(storeVersion: bad, shimVersion: 1), bad)
        }
    }

    func testStoreVersionStaysReadableInVersionName() throws {
        try makeExtension()
        _ = try prepare()
        let m = try manifest()
        XCTAssertEqual(m["version"] as? String, "1.0.\(CEFExtensionShim.version)")
        XCTAssertEqual(m["version_name"] as? String, "1.0")
        try write(#"{"manifest_version": 3, "name": "N", "version": "2.0", "version_name": "2.0 beta"}"#, to: "manifest.json")
        _ = try prepare()
        XCTAssertEqual(try manifest()["version_name"] as? String, "2.0 beta")
        try write(#"{"manifest_version": 3, "name": "N", "version": "2.0-beta"}"#, to: "manifest.json")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .invalidVersion("2.0-beta")) }
    }

    func testDestinationIsUsedAsGivenEvenThroughALink() throws {
        try makeExtension()
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let given = link.appendingPathComponent(fixtureID)
        let result = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: given)
        XCTAssertEqual(result.destination, given)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("\(fixtureID)/manifest.json").path))
    }

    // MARK: - The key

    func testAKeyThatIsNotTheIdsIsRefused() throws {
        try makeExtension()
        var wrong = key!
        wrong[wrong.count - 1] ^= 0xFF
        XCTAssertThrowsError(try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: wrong, destination: destination)) {
            XCTAssertEqual($0 as? CEFExtensionPreparationError, .publicKeyDoesNotMatchID)
        }
        XCTAssertThrowsError(try CEFExtensionPreparer.prepare(source: source, extensionID: "short", publicKey: key, destination: destination)) {
            XCTAssertEqual($0 as? CEFExtensionPreparationError, .invalidExtensionID("short"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAnExistingKeyThatDisagreesIsRefusedAndOneThatAgreesIsKept() throws {
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "key": "AAAA"}"#, to: "manifest.json")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .manifestKeyDisagrees) }
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "key": 7}"#, to: "manifest.json")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .manifestKeyDisagrees) }

        let wrapped = key.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let encoded = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [wrapped]), encoding: .utf8))
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "key": \#(encoded.dropFirst().dropLast())}"#, to: "manifest.json")
        _ = try prepare()
        XCTAssertEqual(try manifest()["key"] as? String, key.base64EncodedString(), "the same key, written on one line")
        XCTAssertEqual(CEFExtensionPreparer.pinnedPublicKey(inManifestAt: source), key)
    }

    // MARK: - Pages

    private func page(_ html: String) throws -> String {
        try makeExtension()
        try write(html, to: "page.html")
        _ = try prepare()
        return try read("page.html")
    }

    func testShimIsFirstInHeadWhenThereIsAHead() throws {
        let out = try page("<!doctype html><html lang=en><HEAD data-x=\"a>b\"><title>t</title><script src=a.js></script></HEAD><body></body></html>")
        XCTAssertEqual(out, "<!doctype html><html lang=en><HEAD data-x=\"a>b\">\(shimTag)<title>t</title><script src=a.js></script></HEAD><body></body></html>")
    }

    func testShimGoesAfterHtmlWhenThereIsNoHead() throws {
        let out = try page("<!DOCTYPE html>\n<html><body><p>no script here</p></body></html>")
        XCTAssertEqual(out, "<!DOCTYPE html>\n<html>\(shimTag)<body><p>no script here</p></body></html>")
    }

    func testShimGoesAfterTheDoctypeNeverBeforeIt() throws {
        let out = try page("<!DOCTYPE html>\n<p>fragment</p>")
        XCTAssertEqual(out, "<!DOCTYPE html>\(shimTag)\n<p>fragment</p>")
        XCTAssertTrue(try page("<p>just text</p>").hasPrefix(shimTag), "a page with nothing at all gets it first")
    }

    func testCommentsAndLookAlikeTagsAreNotTakenForTheHead() throws {
        let out = try page("<!-- <head> --><html><header>x</header><head><meta charset=utf-8></head></html>")
        XCTAssertEqual(out, "<!-- <head> --><html><header>x</header><head>\(shimTag)<meta charset=utf-8></head></html>")
    }

    func testAPageWithAByteOrderMarkKeepsIt() throws {
        try makeExtension()
        try Data([0xEF, 0xBB, 0xBF] + Array("<p>x</p>".utf8)).write(to: source.appendingPathComponent("bom.html"))
        _ = try prepare()
        let bytes = try Data(contentsOf: destination.appendingPathComponent("bom.html"))
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(decoding: bytes.dropFirst(3), as: UTF8.self), shimTag + "<p>x</p>")
    }

    func testTheShimTagNeverLandsInsideAttributesScriptsOrTemplates() throws {
        XCTAssertEqual(try page(#"<html lang="<head>"><head><meta></head>"#), #"<html lang="<head>"><head>\#(shimTag)<meta></head>"#)
        XCTAssertEqual(try page("<html><script>var a='<head>';</script><head></head>"), "<html><script>var a='<head>';</script><head>\(shimTag)</head>")
        XCTAssertEqual(try page("<html><template><head></template><head></head>"), "<html><template><head></template><head>\(shimTag)</head>")
        XCTAssertEqual(try page("<html><textarea><head></textarea><head></head>"), "<html><textarea><head></textarea><head>\(shimTag)</head>")
        XCTAssertEqual(try page("<html><!--><head></head>"), "<html><!--><head>\(shimTag)</head>")
        XCTAssertEqual(try page("<html><!---><head></head>"), "<html><!---><head>\(shimTag)</head>")
        XCTAssertEqual(try page("<html data-x='a>b'><body><p>x</p></body>"), "<html data-x='a>b'>\(shimTag)<body><p>x</p></body>")
        XCTAssertEqual(try page("<?xml version='1.0'?><html><head></head>"), "<?xml version='1.0'?><html><head>\(shimTag)</head>")
    }

    func testOnlyAScriptSourceInTheLayersNamespaceIsRefused() throws {
        XCTAssertNoThrow(try page("<html><head></head><body><p>/__browser_x is a prefix</p><script>var a = '/__browser_y';</script><!-- /__browser_z --></body>"))
        XCTAssertThrowsError(try page(#"<html><head><SCRIPT SRC='/__browser_x.js'></SCRIPT></head>"#))
        XCTAssertThrowsError(try page(#"<html><head><script src=/__browser_x.js></script></head>"#))
        XCTAssertThrowsError(try page(#"<html><head><script src="chrome-extension://\#(fixtureID)/__browser_x.js"></script></head>"#))
    }

    func testUTF16PagesWithoutAByteOrderMarkAreRefused() throws {
        try makeExtension()
        try Data("<html><head></head></html>".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).write(to: source.appendingPathComponent("wide.html"))
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .unsupportedHTMLEncoding("wide.html")) }
    }

    func testAnUnknownWebKitLayerTraceIsRefusedNotCarriedAcross() throws {
        try makeExtension()
        try write("x", to: "__browser_other.js")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .unrecognisedWebKitLayer("__browser_other.js")) }
        try FileManager.default.removeItem(at: source.appendingPathComponent("__browser_other.js"))
        try write("<html><head><script src=\"/__browser_chrome_compat2.js\"></script></head>", to: "page.html")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .unrecognisedWebKitLayer("page.html")) }
    }

    func testUTF16PagesAreRefused() throws {
        try makeExtension()
        try Data([0xFF, 0xFE, 0x3C, 0x00]).write(to: source.appendingPathComponent("wide.html"))
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .unsupportedHTMLEncoding("wide.html")) }
    }

    func testEveryPageAtAnyDepthGetsTheShimAndNonPagesAreCopiedExactly() throws {
        try makeExtension()
        try write("<html><head></head></html>", to: "deep/er/options.htm")
        try write("{\"x\":1}", to: "data/blob.json")
        let result = try prepare()
        XCTAssertEqual(result.pages, ["deep/er/options.htm", "popup.html"])
        XCTAssertTrue(try read("deep/er/options.htm").contains(shimTag))
        XCTAssertEqual(try read("data/blob.json"), "{\"x\":1}")
    }

    // MARK: - WebKit layer

    private func addWebKitLayer(module: Bool = false) throws {
        let tag = CEFExtensionPreparer.WebKitLayer.pageTag
        try write("// compat\n", to: "__browser_chrome_compat.js")
        let wrapper = module
            ? "// Written by the browser: runs __browser_chrome_compat.js ahead of the extension's own worker.\nimport \"/__browser_chrome_compat.js\";\nimport \"/background.js\";\n"
            : "// Written by the browser: runs __browser_chrome_compat.js ahead of the extension's own worker.\nimportScripts(\"/__browser_chrome_compat.js\", \"/background.js\");\n"
        try write(wrapper, to: "__browser_background.js")
        try write("""
        {"manifest_version": 3, "name": "N", "version": "1", "permissions": ["privacy"],
         "background": {"service_worker": "__browser_background.js"\(module ? ", \"type\": \"module\"" : "")}}
        """, to: "manifest.json")
        try write("<html><head>\(tag)<script src=\"x.js\"></script></head></html>", to: "popup.html")
        try write("<html>\(tag)<script src=\"x.js\"></script></html>", to: "popup2.html")
        try write("chrome.runtime.id;", to: "background.js")
    }

    func testTheWebKitLayerIsTakenOutSoOnlyTheCEFShimRemains() throws {
        for module in [false, true] {
            try? FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try addWebKitLayer(module: module)
            let result = try prepare()
            XCTAssertTrue(result.removedWebKitLayer)
            let files = try snapshot(destination)
            XCTAssertNil(files["__browser_chrome_compat.js"])
            XCTAssertNil(files["__browser_background.js"])
            XCTAssertFalse(files.values.contains { String(decoding: $0, as: UTF8.self).contains("__browser_chrome_compat") })
            XCTAssertEqual(try read("popup.html"), "<html><head>\(shimTag)<script src=\"x.js\"></script></head></html>")
            XCTAssertEqual(try read("popup2.html"), "<html>\(shimTag)<script src=\"x.js\"></script></html>")
            let wrapper = try read(CEFExtensionShim.workerFileName(storeVersion: "1"))
            XCTAssertTrue(wrapper.contains("\"/background.js\""))
            XCTAssertEqual((try manifest()["background"] as? [String: Any])?["service_worker"] as? String, CEFExtensionShim.workerFileName(storeVersion: "1"))
            XCTAssertEqual(wrapper.contains("importScripts"), !module)
        }
    }

    func testWebKitBackgroundScriptsListLosesItsFirstEntry() throws {
        try write("""
        {"manifest_version": 3, "name": "N", "version": "1",
         "background": {"scripts": ["__browser_chrome_compat.js", "a.js"], "service_worker": "sw.js"}}
        """, to: "manifest.json")
        try write("1", to: "sw.js")
        try write("// compat", to: "__browser_chrome_compat.js")
        _ = try prepare()
        XCTAssertEqual((try manifest()["background"] as? [String: Any])?["scripts"] as? [String], ["a.js"])
    }

    func testACompatibilityWorkerThatCannotBeReadIsRefused() throws {
        try addWebKitLayer()
        try write("nothing useful here\n", to: "__browser_background.js")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .unreadableCompatibilityWorker) }
    }

    // MARK: - Safe file handling

    func testASymlinkIsRefusedWhereverItPoints() throws {
        try makeExtension()
        let outside = base.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("leak.txt"), withDestinationURL: outside)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .symlink("leak.txt")) }

        try FileManager.default.removeItem(at: source.appendingPathComponent("leak.txt"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("loop"), withDestinationURL: source)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .symlink("loop")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testASpecialFileIsRefused() throws {
        try makeExtension()
        XCTAssertEqual(mkfifo(source.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .specialFile("pipe")) }
    }

    func testACommaInTheDestinationIsRefusedBeforeAnythingIsWritten() throws {
        try makeExtension()
        let bad = base.appendingPathComponent("a,b/\(fixtureID)")
        XCTAssertThrowsError(try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: bad)) {
            XCTAssertEqual($0 as? CEFExtensionPreparationError, .commaInDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("a,b").path))
    }

    func testADestinationInsideOrAroundTheSourceIsRefused() throws {
        try makeExtension()
        let overlapping: [URL] = [source.appendingPathComponent("copy"), base!, source!]
        for bad in overlapping {
            XCTAssertThrowsError(try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: bad)) {
                XCTAssertEqual($0 as? CEFExtensionPreparationError, .destinationOverlapsSource)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path))
    }

    func testADestinationThatIsAFileOrALinkIsRefused() throws {
        try makeExtension()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: destination)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .destinationNotAFolder) }
        try FileManager.default.removeItem(at: destination)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .destinationNotAFolder) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], "nothing was written through the link")
    }

    func testAFailedRunLeavesTheOldCopyAndNoStagingFolder() throws {
        try makeExtension()
        _ = try prepare()
        let before = try snapshot(destination)
        try write("1", to: CEFExtensionShim.fileName)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .nameTaken(CEFExtensionShim.fileName)) }
        XCTAssertEqual(try snapshot(destination), before)

        try FileManager.default.removeItem(at: source.appendingPathComponent(CEFExtensionShim.fileName))
        try write("<p>x</p>", to: "late.html")
        try Data([0xFF, 0xFE]).write(to: source.appendingPathComponent("zzz.html"))
        XCTAssertThrowsError(try prepare())
        XCTAssertEqual(try snapshot(destination), before, "a failure after copying has started still leaves the old copy")
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(names, [fixtureID], "the staging folder is gone")
    }

    func testPreparingTwiceWritesTheSameBytesAndReplacesTheCopy() throws {
        try makeExtension()
        let token = String(repeating: "ab", count: 16)
        _ = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination, token: token)
        let first = try snapshot(destination)
        try write("stale", to: "leftover.txt", in: destination)
        _ = try CEFExtensionPreparer.prepare(source: source, extensionID: fixtureID, publicKey: key, destination: destination, token: token)
        XCTAssertEqual(try snapshot(destination), first)
        XCTAssertNil(try snapshot(destination)["leftover.txt"], "the copy is rebuilt, not patched")
    }

    func testNoFileThePreparerCreatesStartsWithAnUnderscoreAndChromiumsMetadataIsLeftOut() throws {
        try makeExtension()
        try write("{}", to: "_metadata/verified_contents.json")
        try write("{}", to: "_locales/en/messages.json")
        _ = try prepare()
        let created = Set(try snapshot(destination).keys).subtracting(try snapshot(source).keys)
        XCTAssertEqual(created, [CEFExtensionShim.fileName, workerName].reduce(into: Set<String>()) { $0.insert($1) })
        for path in created {
            XCTAssertFalse(path.split(separator: "/").contains { $0.hasPrefix("_") }, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("_metadata").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("_locales/en/messages.json").path), "the extension's own _locales stays")
        let top = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(top, [fixtureID])
    }

    func testTheSourceIsNeverWrittenTo() throws {
        try makeExtension()
        let before = try snapshot(source)
        _ = try prepare()
        XCTAssertEqual(try snapshot(source), before)
    }

    func testPolicyRefusalsStopThePreparer() throws {
        try write(#"{"manifest_version": 2, "name": "N", "version": "1"}"#, to: "manifest.json")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .refused(.notManifestV3(found: 2))) }
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "optional_permissions": ["debugger"]}"#, to: "manifest.json")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .refused(.debuggerPermission)) }
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "permissions": ["management"]}"#, to: "manifest.json")
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .refused(.unsupportedPermission("management"))) }
    }

    func testAMissingWorkerFileIsRefused() throws {
        try makeExtension(worker: #""service_worker": "gone.js""#)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .missingBackgroundFile("gone.js")) }
        try makeExtension(worker: #""service_worker": "../escape.js""#)
        XCTAssertThrowsError(try prepare()) { XCTAssertEqual($0 as? CEFExtensionPreparationError, .missingBackgroundFile("../escape.js")) }
    }

    func testLeftoversAreRemoved() throws {
        let out = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: out.appendingPathComponent(".preparing-x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent(".replaced-x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("keep"), withIntermediateDirectories: true)
        CEFExtensionPreparer.removeLeftovers(in: out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["keep"])
    }
}

final class Crx3PublicKeyTests: XCTestCase {
    private let fixtureID = "pgmnddkfhcbihfijmfgancppilgkimei"

    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "fixture-hello", withExtension: "crx", subdirectory: "Fixtures")))
    }

    func testVerifiedPackageGivesTheKeyTheIdIsMadeFrom() throws {
        let package = try Crx3.verifiedPackage(fixture(), expectedID: fixtureID)
        XCTAssertEqual(ChromeExtensionID.from(publicKey: package.publicKey), fixtureID)
        XCTAssertEqual(package.archive, try Crx3.verifiedArchive(fixture(), expectedID: fixtureID))
    }

    func testAPackageThatDoesNotVerifyGivesNoKey() throws {
        var crx = try fixture()
        crx[crx.count - 5] ^= 0xFF
        XCTAssertThrowsError(try Crx3.verifiedPackage(crx, expectedID: fixtureID))
        XCTAssertThrowsError(try Crx3.verifiedPackage(fixture(), expectedID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    }
}

final class CEFExtensionRevisionLimitTests: XCTestCase {
    func testMaximumRevisionIsTheLargestOneThatGivesAValidVersion() {
        for store in ["1", "1.0", "1.0.2", "1.2.3.4", "1.2.3.65000"] {
            guard let top = CEFExtensionShim.maximumRevision(storeVersion: store) else { return XCTFail(store) }
            XCTAssertNotNil(CEFExtensionShim.preparedVersion(storeVersion: store, shimVersion: CEFExtensionShim.version, revision: top), store)
            if top < 65535 {
                XCTAssertNil(CEFExtensionShim.preparedVersion(storeVersion: store, shimVersion: CEFExtensionShim.version, revision: top + 1), store)
            }
        }
        XCTAssertEqual(CEFExtensionShim.maximumRevision(storeVersion: "1.0"), 65534, "revision plus one must fit a part")
        XCTAssertEqual(CEFExtensionShim.maximumRevision(storeVersion: "1.2.3.4", shimVersion: 3), 65535 - 4 - 3 - 1)
        XCTAssertNil(CEFExtensionShim.maximumRevision(storeVersion: "not a version"))
        XCTAssertNil(CEFExtensionShim.maximumRevision(storeVersion: "1.2.3.65535"))
    }
}
