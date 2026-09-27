import XCTest
import BrowserCore
@testable import BrowserCLI

final class LinkHandlingPreferencesReaderTests: XCTestCase {
    /// The CLI is not bundled, so its own `.standard` is not the app's
    /// domain; reading it made route-test disagree with the running app.
    func testNormalLaunchReadsTheAppsDefaultsDomain() {
        XCTAssertEqual(
            LinkHandlingPreferencesReader.preferencesSuiteName(arguments: ["browser", "route-test", "https://example.com"]),
            "dev.stroud.browser"
        )
    }

    func testProfilesRootReadsTheScratchSuite() {
        let root = "/private/tmp/browser-cli-tests-\(UUID().uuidString)"
        XCTAssertEqual(
            LinkHandlingPreferencesReader.preferencesSuiteName(arguments: ["browser", "route-test", "x", "--profiles-root", root]),
            ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: root)
        )
    }

    func testLittleWindowPreferenceIsReadFromTheResolvedSuite() throws {
        let root = "/private/tmp/browser-cli-tests-\(UUID().uuidString)"
        let arguments = ["browser", "route-test", "x", "--profiles-root", root]
        let suiteName = LinkHandlingPreferencesReader.preferencesSuiteName(arguments: arguments)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(LinkHandlingPreferencesReader.littleWindowForExternalLinks(arguments: arguments))
        defaults.set(true, forKey: "BrowserLittleWindowForExternalLinks")
        XCTAssertTrue(LinkHandlingPreferencesReader.littleWindowForExternalLinks(arguments: arguments))
        XCTAssertTrue(LinkHandlingPreferencesReader.stripTrackingParams(arguments: arguments))
    }
}
