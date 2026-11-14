import XCTest
@testable import WebEngineCore

final class ICloudPasswordsExtensionTests: XCTestCase {
    private func status(
        available: Bool = true, entitled: Bool = true, installed: Bool = true,
        enabled: Bool = true, loaded: Bool = true, errors: Int = 0
    ) -> ICloudPasswordsExtension.Status {
        ICloudPasswordsExtension.status(
            extensionsAvailable: available, hasEntitlement: entitled, installed: installed,
            enabled: enabled, loaded: loaded, errorCount: errors)
    }

    func testNoEngineWithExtensions() {
        XCTAssertEqual(status(available: false, entitled: false, installed: false), .needsNewerMacOS)
        XCTAssertEqual(status(available: false), .needsNewerMacOS)
    }

    func testMissingEntitlementWinsOverInstallState() {
        XCTAssertEqual(status(entitled: false, installed: false), .unavailableInThisBuild)
        XCTAssertEqual(status(entitled: false), .unavailableInThisBuild)
    }

    func testNotInstalled() {
        XCTAssertEqual(status(installed: false, enabled: false, loaded: false), .notInstalled)
    }

    func testReady() {
        XCTAssertEqual(status(), .ready)
    }

    func testTurnedOff() {
        XCTAssertEqual(status(enabled: false, loaded: false), .turnedOff)
    }

    func testNotLoadedIsAProblem() {
        XCTAssertEqual(status(loaded: false), .hasProblem)
    }

    func testErrorsAreAProblemEvenWhenLoaded() {
        XCTAssertEqual(status(errors: 1), .hasProblem)
    }

    func testStoreLinkNamesTheID() {
        XCTAssertTrue(ICloudPasswordsExtension.storeLink.hasSuffix(ICloudPasswordsExtension.storeID))
    }
}
