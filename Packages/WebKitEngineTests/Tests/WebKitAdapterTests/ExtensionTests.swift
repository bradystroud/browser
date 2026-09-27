import WebKit
import XCTest
@testable import WebKitAdapter

/// The real WebKitExtensionManager against real WKWebExtensionControllers:
/// an unpacked extension written to disk, the consent it asks for, what is
/// granted from it, and what a reload that wants more has to ask again.
@available(macOS 15.4, *)
@MainActor
final class ExtensionManagerTests: XCTestCase {
    private final class FakeHost: ExtensionHost {
        var answers: [Bool] = []
        var asked: [ExtensionConsentRequest] = []
        var notices: [String] = []

        func extensionWindows(profileId: String) -> [ExtensionHostWindow] { [] }
        func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool) -> ExtensionHostWindow? { nil }
        func extensionConfirm(_ request: ExtensionConsentRequest) async -> Bool {
            asked.append(request)
            return answers.isEmpty ? false : answers.removeFirst()
        }
        func extensionNotify(_ message: String, profileId: String) { notices.append(message) }
        func extensionsDidChange(profileId: String) {}
    }

    private var manager: WebKitExtensionManager { .shared }
    private var host: FakeHost!
    private var root: URL!
    private var profileId: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brw-ext-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        host = FakeHost()
        let root = root!
        manager.activate(host: host, storageDirectory: { id in
            id.hasPrefix("private-") ? nil : root.appendingPathComponent(id).appendingPathComponent("Extensions", isDirectory: true)
        })
        profileId = UUID().uuidString
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExtension(permissions: [String] = ["storage"], hosts: [String] = ["https://example.com/*"]) throws -> URL {
        let folder = root.appendingPathComponent("dev-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Test Extension",
            "version": "1.0",
            "permissions": permissions,
            "host_permissions": hosts,
            "action": ["default_popup": "popup.html", "default_title": "Test"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><p>popup</p>".utf8).write(to: folder.appendingPathComponent("popup.html"))
        return folder
    }

    private func context(_ id: String) -> WKWebExtensionContext? {
        manager.profile(for: profileId)?.contexts[id]
    }

    func testUnpackedExtensionIsAskedForThenGrantedOnlyWhatWasShown() async throws {
        let folder = try writeExtension()
        host.answers = [true]
        try await manager.loadUnpacked(folder: folder, profileId: profileId)

        XCTAssertEqual(host.asked.count, 1)
        XCTAssertTrue(host.asked[0].message.contains("example.com"), host.asked[0].message)

        let summaries = manager.extensions(profileId: profileId)
        XCTAssertEqual(summaries.count, 1)
        let id = try XCTUnwrap(summaries.first?.id)
        XCTAssertEqual(id, ChromeExtensionID.fromUnpackedPath(folder.resolvingSymlinksInPath().path))
        XCTAssertTrue(summaries[0].isLoaded)
        XCTAssertNotNil(manager.action(extensionId: id, profileId: profileId, tab: nil))

        let running = try XCTUnwrap(context(id))
        XCTAssertEqual(running.baseURL.absoluteString, "chrome-extension://\(id)/")
        XCTAssertTrue(running.hasPermission(.storage))
        XCTAssertTrue(running.hasAccess(to: URL(string: "https://example.com/page")!))
        XCTAssertFalse(running.hasAccess(to: URL(string: "https://other.test/")!))

        let listed = InstalledWebExtensionList.load(from: root.appendingPathComponent(profileId).appendingPathComponent("Extensions/installed.json"))
        XCTAssertEqual(listed.extensions.map(\.id), [id])
        XCTAssertEqual(listed.extensions.first?.grants, ["host:https://example.com/*", "perm:storage"])
    }

    func testDeclinedConsentLeavesNothingBehind() async throws {
        let folder = try writeExtension()
        host.answers = [false]
        do {
            try await manager.loadUnpacked(folder: folder, profileId: profileId)
            XCTFail("a declined extension must not load")
        } catch WebKitExtensionError.cancelled {}
        XCTAssertTrue(manager.extensions(profileId: profileId).isEmpty)
    }

    func testReloadThatWantsMoreAsksAgain() async throws {
        let folder = try writeExtension()
        host.answers = [true]
        try await manager.loadUnpacked(folder: folder, profileId: profileId)
        let id = try XCTUnwrap(manager.extensions(profileId: profileId).first?.id)

        // Same manifest: no question.
        try await manager.reload(extensionId: id, profileId: profileId)
        XCTAssertEqual(host.asked.count, 1)

        // The developer adds a permission and a site; the user says no.
        _ = try writeManifest(into: folder, permissions: ["storage", "tabs"], hosts: ["https://example.com/*", "https://other.test/*"])
        host.answers = [false]
        do {
            try await manager.reload(extensionId: id, profileId: profileId)
            XCTFail("a reload wanting more must not go through without a yes")
        } catch WebKitExtensionError.cancelled {}
        XCTAssertEqual(host.asked.count, 2)
        XCTAssertTrue(host.asked[1].message.contains("other.test"), host.asked[1].message)
        XCTAssertFalse(host.asked[1].message.contains("example.com"), "only what is new is asked about")
        XCTAssertEqual(manager.profile(for: profileId)?.record(id)?.grants, ["host:https://example.com/*", "perm:storage"])
        XCTAssertNotNil(context(id), "the version already agreed to keeps running")

        // Asked again, the user says yes.
        host.answers = [true]
        try await manager.reload(extensionId: id, profileId: profileId)
        let running = try XCTUnwrap(context(id))
        XCTAssertTrue(running.hasPermission(.tabs))
        XCTAssertTrue(running.hasAccess(to: URL(string: "https://other.test/")!))
    }

    func testPrivateProfileGetsNoExtensionsAndWritesNothing() async throws {
        let folder = try writeExtension()
        host.answers = [true]
        do {
            try await manager.loadUnpacked(folder: folder, profileId: "private-\(UUID().uuidString)")
            XCTFail("a private profile has no extensions")
        } catch WebKitExtensionError.unavailable {}
        XCTAssertTrue(host.asked.isEmpty)
        let base = WKWebViewConfiguration()
        let configured = manager.configuration(for: base, profileId: "private-x", initialURL: "https://example.com/")
        XCTAssertNil(configured.webExtensionController)
    }

    func testTabsGetTheirProfilesController() throws {
        let configured = manager.configuration(for: WKWebViewConfiguration(), profileId: profileId, initialURL: "https://example.com/")
        XCTAssertNotNil(configured.webExtensionController)
        XCTAssertTrue(configured.webExtensionController === manager.profile(for: profileId)?.controller)
        let other = manager.configuration(for: WKWebViewConfiguration(), profileId: UUID().uuidString, initialURL: "https://example.com/")
        XCTAssertFalse(other.webExtensionController === configured.webExtensionController, "each profile has its own")
    }

    func testRemoveForgetsItButLeavesTheDevelopersFolder() async throws {
        let folder = try writeExtension()
        host.answers = [true]
        try await manager.loadUnpacked(folder: folder, profileId: profileId)
        let id = try XCTUnwrap(manager.extensions(profileId: profileId).first?.id)
        manager.remove(extensionId: id, profileId: profileId)
        let gone = expectation(description: "removed")
        func poll() {
            if manager.extensions(profileId: profileId).isEmpty { gone.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        await fulfillment(of: [gone], timeout: 10)
        XCTAssertNil(context(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
    }

    /// A site granted through permissions.request under a broader optional
    /// pattern is still granted the next time the extension loads.
    func testNarrowerRuntimeHostGrantSurvivesAReload() async throws {
        let folder = try writeExtension()
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["optional_host_permissions"] = ["https://*/*"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        host.answers = [true, true]
        try await manager.loadUnpacked(folder: folder, profileId: profileId)
        let id = try XCTUnwrap(manager.extensions(profileId: profileId).first?.id)
        let running = try XCTUnwrap(context(id))
        let asked = try WKWebExtension.MatchPattern(string: "https://granted.test/*")
        let controller = try XCTUnwrap(manager.profile(for: profileId)?.controller)
        let (granted, _) = await manager.webExtensionController(controller, promptForPermissionMatchPatterns: [asked], in: nil, for: running)
        XCTAssertEqual(granted.map(\.string), ["https://granted.test/*"])

        try await manager.reload(extensionId: id, profileId: profileId)
        let reloaded = try XCTUnwrap(context(id))
        XCTAssertFalse(reloaded === running)
        XCTAssertTrue(reloaded.hasAccess(to: URL(string: "https://granted.test/page")!))
        XCTAssertFalse(reloaded.hasAccess(to: URL(string: "https://elsewhere.test/")!))
    }

    /// A deleted profile's extensions stop, and nothing writes its folder
    /// back afterwards.
    func testUnloadedProfileIsNotWrittenBack() async throws {
        let folder = try writeExtension()
        host.answers = [true]
        try await manager.loadUnpacked(folder: folder, profileId: profileId)
        let id = try XCTUnwrap(manager.extensions(profileId: profileId).first?.id)
        let running = try XCTUnwrap(context(id))
        let profileFolder = root.appendingPathComponent(profileId)
        manager.unloadProfile(profileId: profileId)
        XCTAssertFalse(running.isLoaded)
        try FileManager.default.removeItem(at: profileFolder)
        await manager.checkForUpdates(profileId: profileId, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileFolder.path))
    }

    func testUnknownPermissionsAreNamedNotHidden() {
        XCTAssertEqual(WebKitExtensionManager.describe(["perm:debugger"]), ["Use the “debugger” permission"])
    }

    @discardableResult
    private func writeManifest(into folder: URL, permissions: [String], hosts: [String]) throws -> URL {
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Test Extension", "version": "1.1",
            "permissions": permissions, "host_permissions": hosts,
            "action": ["default_popup": "popup.html"],
        ]
        let url = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        return url
    }
}

/// Unpacking a store package: what ditto writes, and what is refused
/// before it runs.
final class ExtensionUnpackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brw-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func zip(_ folder: URL) throws -> Data {
        let out = root.appendingPathComponent("\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: out)
    }

    func testPackageUnpacksIntoPlace() throws {
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        try Data("{\"manifest_version\":3,\"name\":\"x\",\"version\":\"1\"}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("_locales/en/messages.json"))
        let target = root.appendingPathComponent("installed/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WebKitExtensionInstaller.unpack(zip(source), into: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("_locales/en/messages.json").path))
    }

    func testPackageWithASymbolicLinkIsRefusedWhole() throws {
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        let target = root.appendingPathComponent("installed/abc", isDirectory: true)
        XCTAssertThrowsError(try WebKitExtensionInstaller.unpack(zip(source), into: target)) {
            XCTAssertEqual($0 as? ZipArchiveError, .symbolicLink("escape"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testReplaceKeepsTheOldFolderWhenTheNewOneIsMissing() throws {
        let destination = root.appendingPathComponent("ext", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try WebKitExtensionInstaller.replace(destination, with: root.appendingPathComponent("missing")))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("manifest.json")), "old")
    }
}
