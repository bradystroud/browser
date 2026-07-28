import XCTest
@testable import BrowserCore

/// Covers the browser-1rp fix -- see ProfilesRootResolver.swift's own doc
/// comment for the bug this exists to prevent (a normal launch's default
/// must stay put; an explicit --profiles-root override must fully redirect
/// both the CEF cache root AND session.json/profiles.json under it).
final class ProfilesRootResolverTests: XCTestCase {
    private let appSupport = "/Users/test/Library/Application Support"

    func testExplicitOverrideIsNilWithoutTheFlag() {
        XCTAssertNil(ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profile", "default"]))
    }

    func testExplicitOverrideReadsTheFollowingArgument() {
        XCTAssertEqual(
            ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profiles-root", "/tmp/scratch"]),
            "/tmp/scratch"
        )
    }

    func testExplicitOverrideIsNilWhenFlagIsTheLastArgument() {
        // No value follows the flag -- must not crash or read out of bounds.
        XCTAssertNil(ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profiles-root"]))
    }

    func testDefaultProfilesRootPathNestsUnderProfiles() {
        XCTAssertEqual(
            ProfilesRootResolver.profilesRootPath(arguments: ["Browser"], appSupportDirectory: appSupport),
            "\(appSupport)/Browser/Profiles"
        )
    }

    func testOverriddenProfilesRootPathIsUsedAsIs() {
        XCTAssertEqual(
            ProfilesRootResolver.profilesRootPath(
                arguments: ["Browser", "--profiles-root", "/tmp/scratch"], appSupportDirectory: appSupport
            ),
            "/tmp/scratch"
        )
    }

    /// The actual regression this task fixes: a normal (unflagged) launch's
    /// session/profile metadata directory must be the exact historical
    /// `<appSupport>/Browser` -- NOT `<appSupport>/Browser/Profiles` (that
    /// would silently orphan a real user's existing session.json/
    /// profiles.json, which is exactly why this is a separate default from
    /// profilesRootPath's).
    func testDefaultMetadataDirectoryIsFlatUnderBrowserNotNestedUnderProfiles() {
        XCTAssertEqual(
            ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: ["Browser"], appSupportDirectory: appSupport),
            "\(appSupport)/Browser"
        )
    }

    /// The other half of the fix: an explicit override must redirect
    /// session.json/profiles.json too, not just CEF's own cache path --
    /// this is what makes --profiles-root actually isolate a test instance.
    func testOverriddenMetadataDirectoryMatchesTheSameOverridePathAsProfilesRoot() {
        let arguments = ["Browser", "--profiles-root", "/tmp/scratch"]
        XCTAssertEqual(
            ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: arguments, appSupportDirectory: appSupport),
            ProfilesRootResolver.profilesRootPath(arguments: arguments, appSupportDirectory: appSupport)
        )
        XCTAssertEqual(
            ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: arguments, appSupportDirectory: appSupport),
            "/tmp/scratch"
        )
    }
}
