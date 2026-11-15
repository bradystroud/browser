import XCTest
@testable import BrowserCore

final class PasswordSavePromptTests: XCTestCase {
    func testNewPasswordIsOfferedOnlyWhenSavingIsOffered() {
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: true, password: "pw", savedPassword: nil), .save)
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: false, password: "pw", savedPassword: nil), .none,
                       "an extension holding the setting asks its own question")
    }

    func testChangedPasswordForAKnownUserIsOfferedForUpdateEitherWay() {
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: true, password: "new", savedPassword: "old"), .update)
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: false, password: "new", savedPassword: "old"), .update,
                       "a stale password the browser fills must still be correctable")
    }

    func testUnchangedOrEmptyPasswordAsksNothing() {
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: true, password: "same", savedPassword: "same"), .none)
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: true, password: "", savedPassword: nil), .none)
        XCTAssertEqual(PasswordSavePrompt.decide(offersSaving: false, password: "", savedPassword: "old"), .none)
    }
}
