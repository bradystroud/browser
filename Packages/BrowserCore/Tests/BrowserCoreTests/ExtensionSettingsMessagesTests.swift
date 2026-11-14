import XCTest
@testable import BrowserCore

final class ExtensionSettingsMessagesTests: XCTestCase {
    private let icloud = "pejdijmoenmkgeppbflobdenhhabjlaj"
    private let other = "abcdefghijklmnopabcdefghijklmnop"
    private let settingName = "services.passwordSavingEnabled"

    /// Requests as they arrive from the engine: decoded JSON.
    private func request(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private func handle(_ json: String, from id: String, _ store: ExtensionControlledSettings, user: Bool = true) throws -> ExtensionSettingsMessages.Outcome {
        ExtensionSettingsMessages.handle(try request(json), from: id, in: store, userValue: { _ in user })
    }

    private func text(_ reply: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]), encoding: .utf8)!
    }

    func testGetSetClear() throws {
        let store = ExtensionControlledSettings(fileURL: nil)
        var outcome = try handle(#"{"setting":"\#(settingName)","op":"get"}"#, from: icloud, store)
        XCTAssertEqual(try text(outcome.reply), #"{"levelOfControl":"controllable_by_this_extension","value":true}"#)
        XCTAssertFalse(outcome.changed)

        outcome = try handle(#"{"setting":"\#(settingName)","op":"set","value":false}"#, from: icloud, store)
        XCTAssertEqual(try text(outcome.reply), #"{"levelOfControl":"controlled_by_this_extension","value":false}"#)
        XCTAssertTrue(outcome.changed)
        XCTAssertFalse(try handle(#"{"setting":"\#(settingName)","op":"set","value":false}"#, from: icloud, store).changed)

        outcome = try handle(#"{"setting":"\#(settingName)","op":"clear"}"#, from: icloud, store)
        XCTAssertEqual(try text(outcome.reply), #"{"levelOfControl":"controllable_by_this_extension","value":true}"#)
        XCTAssertTrue(outcome.changed)
    }

    func testAnotherExtensionIsRefusedAndSeesTheHolder() throws {
        let store = ExtensionControlledSettings(fileURL: nil)
        _ = try handle(#"{"setting":"\#(settingName)","op":"set","value":false}"#, from: icloud, store)
        let refused = try handle(#"{"setting":"\#(settingName)","op":"set","value":true}"#, from: other, store)
        XCTAssertEqual(try text(refused.reply), #"{"error":"Another extension controls this setting."}"#)
        XCTAssertFalse(refused.changed)
        XCTAssertEqual(try text(try handle(#"{"setting":"\#(settingName)","op":"get"}"#, from: other, store).reply),
                       #"{"levelOfControl":"controlled_by_other_extensions","value":false}"#)
        XCTAssertFalse(try handle(#"{"setting":"\#(settingName)","op":"clear"}"#, from: other, store).changed)
        XCTAssertEqual(store.holder(of: .passwordSavingEnabled), icloud)
    }

    func testOnlyKnownSettingsAndRealBooleans() throws {
        let store = ExtensionControlledSettings(fileURL: nil)
        for bad in [
            #"{"setting":"services.autofillCreditCardEnabled","op":"set","value":false}"#,
            #"{"setting":"\#(settingName)","op":"set","value":0}"#,
            #"{"setting":"\#(settingName)","op":"set","value":"false"}"#,
            #"{"setting":"\#(settingName)","op":"delete"}"#,
            #"{"op":"get"}"#,
            #"["get"]"#,
        ] {
            let outcome = try handle(bad, from: icloud, store)
            XCTAssertNotNil(outcome.reply["error"], bad)
            XCTAssertFalse(outcome.changed, bad)
        }
        XCTAssertNil(store.holder(of: .passwordSavingEnabled))
    }

    func testTheCallerIsNeverReadFromTheMessage() throws {
        let store = ExtensionControlledSettings(fileURL: nil)
        _ = try handle(#"{"setting":"\#(settingName)","op":"set","value":false,"extensionId":"\#(other)"}"#, from: icloud, store)
        XCTAssertEqual(store.holder(of: .passwordSavingEnabled), icloud)
    }

    func testChangeIsTailoredToEachListener() throws {
        let store = ExtensionControlledSettings(fileURL: nil)
        try store.set(.passwordSavingEnabled, to: false, by: icloud)
        XCTAssertEqual(try text(ExtensionSettingsMessages.change(.passwordSavingEnabled, for: icloud, in: store, userValue: true)),
                       #"{"levelOfControl":"controlled_by_this_extension","setting":"\#(settingName)","value":false}"#)
        XCTAssertEqual(try text(ExtensionSettingsMessages.change(.passwordSavingEnabled, for: other, in: store, userValue: true)),
                       #"{"levelOfControl":"controlled_by_other_extensions","setting":"\#(settingName)","value":false}"#)
    }
}
