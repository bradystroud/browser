import XCTest
@testable import WebEngineCore

final class ICloudPasswordsExtensionTests: XCTestCase {
    private func status(
        available: Bool = true, entitled: Bool = true, installed: Bool = true,
        enabled: Bool = true, loaded: Bool = true, errors: Int = 0, paired: Bool = false
    ) -> ICloudPasswordsExtension.Status {
        ICloudPasswordsExtension.status(
            extensionsAvailable: available, hasEntitlement: entitled, installed: installed,
            enabled: enabled, loaded: loaded, errorCount: errors, paired: paired)
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

    func testPaired() {
        XCTAssertEqual(status(paired: true), .paired)
        XCTAssertEqual(status(enabled: false, loaded: false, paired: true), .turnedOff, "a paired flag left over means nothing once off")
        XCTAssertEqual(status(errors: 1, paired: true), .hasProblem)
    }

    func testPairedNeedsThePairedIconAndARunningHelper() {
        for file in ICloudPasswordsExtension.pairedIconFiles {
            XCTAssertTrue(ICloudPasswordsExtension.isPaired(iconFile: file, helperRunning: true), file)
            XCTAssertFalse(ICloudPasswordsExtension.isPaired(iconFile: file, helperRunning: false), "a helper that exited ended the session: \(file)")
        }
        for file in ICloudPasswordsExtension.unpairedIconFiles {
            XCTAssertFalse(ICloudPasswordsExtension.isPaired(iconFile: file, helperRunning: true), file)
        }
        XCTAssertFalse(ICloudPasswordsExtension.isPaired(iconFile: nil, helperRunning: true), "the default icon, or one that matches no file")
        XCTAssertTrue(Set(ICloudPasswordsExtension.pairedIconFiles).isDisjoint(with: ICloudPasswordsExtension.unpairedIconFiles))
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
