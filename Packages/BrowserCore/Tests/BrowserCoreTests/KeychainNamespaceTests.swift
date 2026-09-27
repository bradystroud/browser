import XCTest
@testable import BrowserCore

/// Pure derivation only -- nothing here reads or writes the Keychain.
final class KeychainNamespaceTests: XCTestCase {
    func testRealInstallKeepsItsExistingIdentity() {
        XCTAssertEqual(KeychainNamespace.qualifier(profilesRootOverride: nil), "")
        XCTAssertEqual(KeychainNamespace.passwordSecurityDomain(profileName: "Work", qualifier: ""),
                       "dev.stroud.browser.password.Work")
        XCTAssertEqual(KeychainNamespace.cardService(profileName: "Work", qualifier: ""),
                       "dev.stroud.browser.card.Work")
    }

    func testScratchRootGetsItsOwnNamespace() {
        let qualifier = KeychainNamespace.qualifier(profilesRootOverride: "/private/tmp/test-a")
        XCTAssertFalse(qualifier.isEmpty)
        XCTAssertNotEqual(KeychainNamespace.passwordSecurityDomain(profileName: "default", qualifier: qualifier),
                          KeychainNamespace.passwordSecurityDomain(profileName: "default", qualifier: ""))
        XCTAssertNotEqual(KeychainNamespace.cardService(profileName: "default", qualifier: qualifier),
                          KeychainNamespace.cardService(profileName: "default", qualifier: ""))
    }

    func testSameRootIsStableAndDifferentRootsDiffer() {
        let a = KeychainNamespace.qualifier(profilesRootOverride: "/private/tmp/test-a")
        XCTAssertEqual(a, KeychainNamespace.qualifier(profilesRootOverride: "/private/tmp/test-a"))
        XCTAssertNotEqual(a, KeychainNamespace.qualifier(profilesRootOverride: "/private/tmp/test-b"))
        // A fixed value, so a change to the derivation that would orphan a
        // scratch root's items between launches is caught here.
        XCTAssertEqual(a, "-scratch-" + KeychainNamespace.stableHash("/private/tmp/test-a"))
        XCTAssertEqual(KeychainNamespace.stableHash(""), "cbf29ce484222325")
    }

    func testNoRealProfileNameCanReachAScratchNamespace() {
        let qualifier = KeychainNamespace.qualifier(profilesRootOverride: "/private/tmp/test-a")
        let scratch = KeychainNamespace.passwordSecurityDomain(profileName: "default", qualifier: qualifier)
        // A real domain always has "password." right before the profile
        // name; a scratch one never does.
        XCTAssertFalse(scratch.hasPrefix("dev.stroud.browser.password."))
        let hostile = String(qualifier.dropFirst()) + ".default"
        XCTAssertNotEqual(KeychainNamespace.passwordSecurityDomain(profileName: hostile, qualifier: ""), scratch)
    }

    func testCanonicalOverrideFeedsTheQualifier() {
        let viaTmp = ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profiles-root", "/tmp/kc-ns-test"])
        let viaPrivate = ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profiles-root", "/private/tmp/kc-ns-test"])
        XCTAssertEqual(KeychainNamespace.qualifier(profilesRootOverride: viaTmp),
                       KeychainNamespace.qualifier(profilesRootOverride: viaPrivate))
    }
}
