import XCTest
@testable import WebEngineCore

final class ExtensionToolbarRuleTests: XCTestCase {
    func testMenuListsWhatRunsWhetherSetUpOrNot() {
        XCTAssertTrue(ExtensionToolbarRule.listsInMenu(isLoaded: true, isEnabled: true, hasActionInTab: false))
        XCTAssertTrue(ExtensionToolbarRule.listsInMenu(isLoaded: false, isEnabled: true, hasActionInTab: true), "running only in the tab's engine")
        XCTAssertFalse(ExtensionToolbarRule.listsInMenu(isLoaded: false, isEnabled: false, hasActionInTab: true))
        XCTAssertFalse(ExtensionToolbarRule.listsInMenu(isLoaded: false, isEnabled: true, hasActionInTab: false))
    }

    func testPinnedButtonWaitsUntilSetUp() {
        for (loaded, enabled, action) in [(true, true, false), (false, true, true)] {
            XCTAssertFalse(ExtensionToolbarRule.showsPinnedButton(isLoaded: loaded, isEnabled: enabled, hasActionInTab: action, isSetUp: false))
            XCTAssertTrue(ExtensionToolbarRule.showsPinnedButton(isLoaded: loaded, isEnabled: enabled, hasActionInTab: action, isSetUp: true))
            XCTAssertTrue(ExtensionToolbarRule.showsPinnedButton(isLoaded: loaded, isEnabled: enabled, hasActionInTab: action, isSetUp: nil),
                          "an extension with nothing to set up keeps its button")
        }
        XCTAssertFalse(ExtensionToolbarRule.showsPinnedButton(isLoaded: false, isEnabled: false, hasActionInTab: false, isSetUp: true))
    }
}
