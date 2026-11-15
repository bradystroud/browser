import XCTest
@testable import WebEngineCore

final class ChromiumProfilePreferencesTests: XCTestCase {
    private var folder: URL!
    private var file: URL { ChromiumProfilePreferences.fileURL(inProfileFolder: folder) }
    private let blocked = ChromiumProfilePreferences.commandLineExtensionsBlocked(true)
    private let allowed = ChromiumProfilePreferences.commandLineExtensionsBlocked(false)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)/Profile", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func blocklist() throws -> [String]? {
        ((try json())["extensions"] as? [String: Any])?["extension_install_type_blocklist"] as? [String]
    }

    private func seed(_ text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testMissingFileAndFolderAreCreated() throws {
        XCTAssertEqual(try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder), .created)
        XCTAssertEqual(try blocklist(), ["command_line"])
    }

    func testClearingWhenThereIsNoFileCreatesNothing() throws {
        XCTAssertEqual(try ChromiumProfilePreferences.apply([allowed], toProfileFolder: folder), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnrelatedKeysSurviveEveryEdit() throws {
        try seed("""
        {"browser": {"window_placement": {"left": 10, "top": 2.5}, "flag": true}, "profile": {"name": "Work \u{00e9}", "url": "https://a.example/x"},
         "extensions": {"settings": {"abc": {"state": 1}}, "extension_install_type_blocklist": ["policy"]}, "big": 13123456789012345}
        """)
        XCTAssertEqual(try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder), .updated)
        var root = try json()
        XCTAssertEqual(try blocklist(), ["policy", "command_line"])
        XCTAssertEqual((root["browser"] as? [String: Any])?["flag"] as? Bool, true)
        XCTAssertEqual(((root["browser"] as? [String: Any])?["window_placement"] as? [String: Any])?["top"] as? Double, 2.5)
        XCTAssertEqual((root["profile"] as? [String: Any])?["name"] as? String, "Work \u{00e9}")
        XCTAssertEqual((root["profile"] as? [String: Any])?["url"] as? String, "https://a.example/x")
        XCTAssertEqual(root["big"] as? Int, 13123456789012345)
        XCTAssertNotNil(((root["extensions"] as? [String: Any])?["settings"] as? [String: Any])?["abc"])

        XCTAssertEqual(try ChromiumProfilePreferences.apply([allowed], toProfileFolder: folder), .updated)
        root = try json()
        XCTAssertEqual(try blocklist(), ["policy"], "only command_line is removed")
        XCTAssertNotNil(((root["extensions"] as? [String: Any])?["settings"] as? [String: Any])?["abc"])
    }

    func testSetThenClearLeavesNoTrace() throws {
        try seed(#"{"a": 1}"#)
        try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder)
        XCTAssertEqual(try blocklist(), ["command_line"])
        try ChromiumProfilePreferences.apply([allowed], toProfileFolder: folder)
        let root = try json()
        XCTAssertEqual(root["a"] as? Int, 1)
        XCTAssertNil(root["extensions"], "the list and the object it was the last member of are gone")
    }

    func testRepeatedEditsDoNotWriteAgain() throws {
        try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder)
        XCTAssertEqual(try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder), .unchanged)
        XCTAssertEqual(try blocklist(), ["command_line"], "no duplicate member")
        try seed(#"{"extensions": {}}"#)
        XCTAssertEqual(try ChromiumProfilePreferences.apply([allowed], toProfileFolder: folder), .unchanged, "an empty object that was already there stays")
    }

    func testAFileThatDoesNotParseIsLeftAloneAndReported() throws {
        for text in ["{ broken", "", "[1, 2]", "\"text\""] {
            try seed(text)
            guard case .leftAlone = try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder) else {
                return XCTFail("\(text) should be left alone")
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
    }

    func testAParentThatIsNotAnObjectIsNotReplaced() throws {
        try seed(#"{"extensions": "odd"}"#)
        guard case .leftAlone(let reason) = try ChromiumProfilePreferences.apply([blocked], toProfileFolder: folder) else {
            return XCTFail("a skipped edit is not 'unchanged'")
        }
        XCTAssertTrue(reason.contains("extensions.extension_install_type_blocklist"), reason)
        XCTAssertEqual(try json()["extensions"] as? String, "odd")
        try seed(#"{"extensions": 5, "other": 1}"#)
        let two = ChromiumProfilePreferences.Change(path: ["fine"], operation: .set(.int(1)))
        guard case .leftAlone = try ChromiumProfilePreferences.apply([two, blocked], toProfileFolder: folder) else { return XCTFail() }
        XCTAssertNil(try json()["fine"], "nothing is written when one edit cannot be made")
    }

    /// Other settings are other `Change`s on the same file: nothing here is
    /// specific to the blocklist.
    func testOtherSettingsFitTheSameShape() throws {
        let incognito = ChromiumProfilePreferences.Change(path: ["incognito", "mode_availability"], operation: .set(.int(2)))
        let other = ChromiumProfilePreferences.Change(path: ["some", "a.b", "flag"], operation: .set(.bool(true)))
        try ChromiumProfilePreferences.apply([blocked, incognito, other], toProfileFolder: folder)
        let root = try json()
        XCTAssertEqual((root["incognito"] as? [String: Any])?["mode_availability"] as? Int, 2)
        XCTAssertEqual((((root["some"] as? [String: Any])?["a.b"]) as? [String: Any])?["flag"] as? Bool, true)
        XCTAssertEqual(try blocklist(), ["command_line"])
        try ChromiumProfilePreferences.apply([.init(path: ["incognito", "mode_availability"], operation: .remove)], toProfileFolder: folder)
        XCTAssertNil(try json()["incognito"])
        XCTAssertNotNil(try blocklist())
    }
}
