import XCTest
@testable import WebEngineCore

final class ExtensionIsolationPolicyTests: XCTestCase {
    private let real = ["/Users/u/Library/Application Support/Browser"]
    private let flag = ExtensionIsolationPolicy.allowAgentExtensionsFlag

    func testExtensionSchemesAreRecognised() {
        XCTAssertTrue(ExtensionIsolationPolicy.isExtensionURL("chrome-extension://abc/page.html"))
        XCTAssertTrue(ExtensionIsolationPolicy.isExtensionURL("  CHROME-EXTENSION://abc/"))
        XCTAssertTrue(ExtensionIsolationPolicy.isExtensionURL("safari-web-extension://x/"))
        XCTAssertTrue(ExtensionIsolationPolicy.isExtensionURL("webkit-extension://x/"))
        XCTAssertFalse(ExtensionIsolationPolicy.isExtensionURL("https://chrome-extension.example/"))
        XCTAssertFalse(ExtensionIsolationPolicy.isExtensionURL("about:blank"))
        XCTAssertFalse(ExtensionIsolationPolicy.isExtensionURL(""))
    }

    func testNormalLaunchNeverAllows() {
        XCTAssertFalse(ExtensionIsolationPolicy.agentPagesMayRunExtensions(
            arguments: ["Browser"], profilesRootOverride: nil, realDataDirectories: real))
    }

    func testFlagWithoutScratchRootIsIgnored() {
        XCTAssertFalse(ExtensionIsolationPolicy.agentPagesMayRunExtensions(
            arguments: ["Browser", flag], profilesRootOverride: nil, realDataDirectories: real))
    }

    func testScratchRootWithoutFlagIsIgnored() {
        XCTAssertFalse(ExtensionIsolationPolicy.agentPagesMayRunExtensions(
            arguments: ["Browser", "--profiles-root", "/private/tmp/x"], profilesRootOverride: "/private/tmp/x", realDataDirectories: real))
    }

    func testFlagAndScratchRootAllow() {
        XCTAssertTrue(ExtensionIsolationPolicy.agentPagesMayRunExtensions(
            arguments: ["Browser", "--profiles-root", "/private/tmp/x", flag], profilesRootOverride: "/private/tmp/x", realDataDirectories: real))
    }

    func testRealRootGivenAsOverrideIsRefused() {
        for root in [
            "/Users/u/Library/Application Support/Browser",
            "/Users/u/Library/Application Support/Browser/",
            "/Users/u/Library/Application Support/Browser/Profiles",
            "/Users/u/Library/Application Support/Browser/./Profiles/../Profiles",
            "/Users/u/Library/Application Support",
            "/Users/u",
            "/",
        ] {
            XCTAssertFalse(ExtensionIsolationPolicy.agentPagesMayRunExtensions(
                arguments: ["Browser", "--profiles-root", root, flag], profilesRootOverride: root, realDataDirectories: real), root)
        }
    }

    func testSiblingWithSharedPrefixIsAScratchRoot() {
        let root = "/Users/u/Library/Application Support/Browser-scratch"
        XCTAssertTrue(ExtensionIsolationPolicy.agentPagesMayRunExtensions(
            arguments: [flag], profilesRootOverride: root, realDataDirectories: real))
    }
}
