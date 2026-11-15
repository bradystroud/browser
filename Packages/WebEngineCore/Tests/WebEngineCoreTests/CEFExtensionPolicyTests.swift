import XCTest
@testable import WebEngineCore

final class CEFExtensionPolicyTests: XCTestCase {
    private func verdict(_ json: String) -> CEFExtensionPolicy.Verdict {
        CEFExtensionPolicy.evaluate(manifestData: Data(json.utf8))
    }

    func testManifestV3WithOrdinaryPermissionsRuns() {
        let v = verdict("""
        {"manifest_version": 3, "permissions": ["storage", "tabs", "storage"],
         "host_permissions": ["https://*.example.com/*", "<all_urls>"],
         "optional_permissions": ["history"], "optional_host_permissions": ["https://*/*"],
         "content_scripts": [{"matches": ["https://a.example/*", "<all_urls>"], "js": ["c.js"]}, {"matches": ["https://b.example/*"]}]}
        """)
        XCTAssertTrue(v.canRun)
        XCTAssertNil(v.reason)
        XCTAssertEqual(v.permissions, ["storage", "tabs"])
        XCTAssertEqual(v.hostPatterns, ["https://*.example.com/*", "http://*/*", "https://*/*", "https://a.example/*", "https://b.example/*"])
        XCTAssertEqual(v.optionalPermissions, ["history"])
        XCTAssertEqual(v.optionalHostPatterns, ["https://*/*"])
        XCTAssertEqual(v.grants, WebExtensionGrants.make(permissions: v.permissions, matchPatterns: v.hostPatterns))
    }

    func testOnlyManifestV3Runs() {
        XCTAssertEqual(verdict(#"{"manifest_version": 2}"#).refusal, .notManifestV3(found: 2))
        XCTAssertEqual(verdict(#"{"name": "x"}"#).refusal, .notManifestV3(found: nil))
        XCTAssertEqual(verdict(#"{"manifest_version": 4}"#).refusal, .notManifestV3(found: 4))
        XCTAssertEqual(verdict(#"{"manifest_version": 2}"#).reason, "It uses Manifest V2. Only Manifest V3 extensions run in Chromium tabs.")
        XCTAssertFalse(verdict(#"{"manifest_version": 2}"#).canRun)
    }

    func testDebuggerIsRefusedWhetherRequiredOrOptional() {
        XCTAssertEqual(verdict(#"{"manifest_version": 3, "permissions": ["tabs", "debugger"]}"#).refusal, .debuggerPermission)
        XCTAssertEqual(verdict(#"{"manifest_version": 3, "optional_permissions": ["debugger"]}"#).refusal, .debuggerPermission)
        XCTAssertNotNil(verdict(#"{"manifest_version": 3, "permissions": ["debugger"]}"#).reason)
        XCTAssertEqual(verdict(#"{"manifest_version": 3, "permissions": ["debugger"]}"#).permissions, ["debugger"],
                       "a refused extension still reports what it asked for")
        XCTAssertTrue(verdict(#"{"manifest_version": 3, "host_permissions": ["https://debugger.example/*"]}"#).canRun)
    }

    func testUnreadableManifests() {
        for text in ["", "not json", "[1, 2]"] {
            XCTAssertEqual(verdict(text).refusal, .unreadableManifest, text)
        }
    }

    func testMatchPatternsInPermissionsAreNotPermissionsInManifestV3() {
        let v = verdict(#"{"manifest_version": 3, "permissions": ["tabs", "<all_urls>", "https://x.example/*"]}"#)
        XCTAssertEqual(v.permissions, ["tabs"])
        XCTAssertEqual(v.hostPatterns, [])
    }

    func testTheBridgeHostPermissionIsNotShownAsAGrant() {
        let v = verdict(#"{"manifest_version": 3, "host_permissions": ["https://extension-bridge.browser.invalid/*", "https://a.example/*"]}"#)
        XCTAssertEqual(v.hostPatterns, ["https://a.example/*"])
    }

    func testCommentsAndByteOrderMarkAreAccepted() {
        XCTAssertTrue(verdict("\u{FEFF}// c\n{\"manifest_version\": 3}").canRun)
    }

    func testPermissionsThatActOnTheWholeProfileAreRefusedRequiredOrOptional() {
        for name in ["management", "contentSettings", "browsingData", "webAuthenticationProxy"] {
            for key in ["permissions", "optional_permissions"] {
                let v = verdict(#"{"manifest_version": 3, "\#(key)": ["tabs", "\#(name)"]}"#)
                XCTAssertEqual(v.refusal, .unsupportedPermission(name), "\(key) \(name)")
                XCTAssertTrue(v.reason?.contains(name) == true, name)
            }
        }
        XCTAssertEqual(verdict(#"{"manifest_version": 3, "permissions": ["debugger", "management"]}"#).refusal, .debuggerPermission)
        XCTAssertTrue(verdict(#"{"manifest_version": 3, "permissions": ["tabs", "storage", "scripting"]}"#).canRun)
    }

    func testProxyAndPrivacyRunWithConsentWordingThatNamesTheChromiumTabs() {
        let v = verdict(#"{"manifest_version": 3, "permissions": ["proxy", "tabs"], "optional_permissions": ["privacy"]}"#)
        XCTAssertTrue(v.canRun)
        XCTAssertEqual(Set(v.consentNotes.keys), ["proxy", "privacy"])
        for note in v.consentNotes.values { XCTAssertTrue(note.contains("Chromium tabs"), note) }
        XCTAssertTrue(verdict(#"{"manifest_version": 3, "permissions": ["tabs"]}"#).consentNotes.isEmpty)
    }

    func testManifestVersionMustBeExactlyThree() {
        XCTAssertEqual(verdict(#"{"manifest_version": 3.5}"#).refusal, .invalidManifestVersion)
        XCTAssertEqual(verdict(#"{"manifest_version": true}"#).refusal, .invalidManifestVersion)
        XCTAssertEqual(verdict(#"{"manifest_version": "3"}"#).refusal, .invalidManifestVersion)
        XCTAssertTrue(verdict(#"{"manifest_version": 3.5}"#).reason?.contains("invalid manifest version") == true)
        XCTAssertTrue(verdict(#"{"manifest_version": 3.0}"#).canRun)
    }

    func testNothingGrantedCoversFileUrls() {
        XCTAssertEqual(CEFExtensionPolicy.webPatterns(["<all_urls>"]), ["http://*/*", "https://*/*"], "<all_urls> includes file: in Chrome's rules")
        XCTAssertEqual(CEFExtensionPolicy.webPatterns(["file:///*", "FILE://*/*", "file://*"]), [])
        XCTAssertEqual(CEFExtensionPolicy.webPatterns(["*://*/*", "https://*.a.example/*", "http://localhost/*"]), ["*://*/*", "https://*.a.example/*", "http://localhost/*"], "*:// is http and https only")
        XCTAssertEqual(CEFExtensionPolicy.webPatterns(["<all_urls>", "https://*/*", "file:///a"]), ["http://*/*", "https://*/*"], "repeats go")
        let v = verdict(#"{"manifest_version": 3, "host_permissions": ["<all_urls>"], "optional_host_permissions": ["file:///*", "<all_urls>"], "content_scripts": [{"matches": ["file:///*"]}]}"#)
        XCTAssertEqual(v.hostPatterns, ["http://*/*", "https://*/*"])
        XCTAssertEqual(v.optionalHostPatterns, ["http://*/*", "https://*/*"])
        XCTAssertEqual(v.grants, ["host:http://*/*", "host:https://*/*"])
    }
}
