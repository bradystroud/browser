import XCTest
@testable import WebEngineCore

/// Permissions this browser implements itself and the engine does not know
/// (`privacy`): read from the manifest, asked for once, and a refusal kept.
final class AppImplementedPermissionTests: XCTestCase {
    func testOnlyAppImplementedPermissionsAreReadFromTheManifest() {
        let manifest: [String: Any] = ["permissions": ["privacy", "storage", "nativeMessaging", 7], "optional_permissions": ["privacy"]]
        XCTAssertEqual(WebExtensionGrants.appImplementedPermissions(declaredIn: manifest), ["privacy"])
        XCTAssertEqual(WebExtensionGrants.appImplementedPermissions(declaredIn: ["permissions": ["storage"]]), [])
        XCTAssertEqual(WebExtensionGrants.appImplementedPermissions(declaredIn: [:]), [])
    }

    func testUnaskedLeavesOutWhatWasGrantedOrRefused() {
        var record = InstalledWebExtension(id: "x", source: .webStore, name: "X", version: "1",
                                           grants: ["perm:nativeMessaging", "host:*://*/*"])
        let requested = ["perm:nativeMessaging", "perm:privacy", "host:*://*/*"]
        XCTAssertEqual(WebExtensionGrants.unasked(requested, in: record), ["perm:privacy"])
        record.declinedGrants = ["perm:privacy"]
        XCTAssertEqual(WebExtensionGrants.unasked(requested, in: record), [])
        record.declinedGrants = nil
        record.grants.append("perm:privacy")
        XCTAssertEqual(WebExtensionGrants.unasked(requested, in: record), [])
    }

    func testOnlyAppImplemented() {
        XCTAssertTrue(WebExtensionGrants.onlyAppImplemented(["perm:privacy"]))
        XCTAssertFalse(WebExtensionGrants.onlyAppImplemented(["perm:privacy", "perm:tabs"]))
        XCTAssertFalse(WebExtensionGrants.onlyAppImplemented(["perm:privacy", "host:*://*/*"]))
        XCTAssertFalse(WebExtensionGrants.onlyAppImplemented([]))
    }

    /// Records written before the field existed still load, and a record
    /// that never refused anything is written exactly as before.
    func testDeclinedGrantsIsOptionalOnDisk() throws {
        let old = #"{"extensions":[{"enabled":true,"grants":["perm:storage"],"id":"x","installedAt":"2026-11-15T00:00:00Z","name":"X","pinned":false,"source":"webStore","version":"1"}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("installed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(old.utf8).write(to: url)
        var list = InstalledWebExtensionList.load(from: url)
        XCTAssertEqual(list.extensions.first?.declinedGrants, nil)
        try list.save(to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("declinedGrants"))
        list.extensions[0].declinedGrants = ["perm:privacy"]
        try list.save(to: url)
        XCTAssertEqual(InstalledWebExtensionList.load(from: url).extensions.first?.declinedGrants, ["perm:privacy"])
    }
}
