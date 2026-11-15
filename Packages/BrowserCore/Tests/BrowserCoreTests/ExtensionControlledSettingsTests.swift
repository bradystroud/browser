import XCTest
@testable import BrowserCore

final class ExtensionControlledSettingsTests: XCTestCase {
    private var dir: URL!
    private let saving = ExtensionControllableSetting.passwordSavingEnabled
    private let icloud = "pejdijmoenmkgeppbflobdenhhabjlaj"
    private let other = "abcdefghijklmnopabcdefghijklmnop"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ext-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("extension-settings.json") }

    func testChromeNameIsTheRawValue() {
        XCTAssertEqual(saving.rawValue, "services.passwordSavingEnabled")
    }

    func testUnheldSettingIsTheUsersAndControllable() {
        let store = ExtensionControlledSettings(fileURL: file)
        XCTAssertEqual(store.details(of: saving, for: icloud, userValue: true),
                       ExtensionSettingDetails(value: true, levelOfControl: .controllableByThisExtension))
        XCTAssertEqual(store.details(of: saving, for: icloud, userValue: false).value, false)
        XCTAssertNil(store.holder(of: saving))
        XCTAssertTrue(store.effectiveValue(of: saving, userValue: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "reading writes nothing")
    }

    func testHolderControlsTheValueAndOthersSeeThat() throws {
        let store = ExtensionControlledSettings(fileURL: file)
        XCTAssertTrue(try store.set(saving, to: false, by: icloud))
        XCTAssertEqual(store.holder(of: saving), icloud)
        XCTAssertFalse(store.effectiveValue(of: saving, userValue: true), "the holder's value beats the user's")
        XCTAssertEqual(store.details(of: saving, for: icloud, userValue: true),
                       ExtensionSettingDetails(value: false, levelOfControl: .controlledByThisExtension))
        XCTAssertEqual(store.details(of: saving, for: other, userValue: true),
                       ExtensionSettingDetails(value: false, levelOfControl: .controlledByOtherExtensions))
        XCTAssertThrowsError(try store.set(saving, to: true, by: other)) { error in
            XCTAssertEqual(error as? ExtensionSettingError, .controlledByOtherExtension)
        }
        XCTAssertFalse(store.effectiveValue(of: saving, userValue: true), "a refused set changes nothing")
        XCTAssertFalse(try store.set(saving, to: false, by: icloud), "setting the same value again is no change")
    }

    func testClearOnlyByTheHolderAndTheUsersValueComesBack() throws {
        let store = ExtensionControlledSettings(fileURL: file)
        try store.set(saving, to: false, by: icloud)
        XCTAssertFalse(store.clear(saving, by: other))
        XCTAssertEqual(store.holder(of: saving), icloud)
        XCTAssertTrue(store.clear(saving, by: icloud))
        XCTAssertNil(store.holder(of: saving))
        XCTAssertTrue(store.effectiveValue(of: saving, userValue: true))
        XCTAssertFalse(store.clear(saving, by: icloud), "clearing what nobody holds changes nothing")
    }

    func testReleaseLetsGoOfEverythingTheExtensionHolds() throws {
        let store = ExtensionControlledSettings(fileURL: file)
        try store.set(saving, to: false, by: icloud)
        XCTAssertEqual(store.release(extensionId: other), [])
        XCTAssertEqual(store.release(extensionId: icloud), [saving])
        XCTAssertNil(store.holder(of: saving))
        XCTAssertEqual(ExtensionControlledSettings(fileURL: file).holder(of: saving), nil, "the release is saved")
    }

    func testControlSurvivesARelaunch() throws {
        try ExtensionControlledSettings(fileURL: file).set(saving, to: false, by: icloud)
        let reopened = ExtensionControlledSettings(fileURL: file)
        XCTAssertEqual(reopened.holder(of: saving), icloud)
        XCTAssertFalse(reopened.effectiveValue(of: saving, userValue: true))
    }

    func testFileHoldsOnlyNamesIdsAndValues() throws {
        try ExtensionControlledSettings(fileURL: file).set(saving, to: false, by: icloud)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        XCTAssertEqual(Set(json.keys), ["services.passwordSavingEnabled"])
        XCTAssertEqual(json["services.passwordSavingEnabled"]?["extensionId"] as? String, icloud)
        XCTAssertEqual(json["services.passwordSavingEnabled"]?["value"] as? Bool, false)
    }

    func testSettingsALaterVersionKnowsSurviveASave() throws {
        let later = #"{"websites.futureSetting":{"extensionId":"\#(other)","value":true}}"#
        try Data(later.utf8).write(to: file)
        let store = ExtensionControlledSettings(fileURL: file)
        try store.set(saving, to: false, by: icloud)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(json["websites.futureSetting"])
        store.release(extensionId: other)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(after["websites.futureSetting"], "release also lets go of settings this version does not know")
    }

    func testMemoryOnlyStoreWritesNothing() throws {
        let store = ExtensionControlledSettings(fileURL: nil)
        try store.set(saving, to: false, by: icloud)
        XCTAssertEqual(store.holder(of: saving), icloud)
        store.release(extensionId: icloud)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
