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
        // A path with no symlinked component in it (unlike /tmp below)
        // round-trips unchanged through resolvingSymlinksInPath().
        XCTAssertEqual(
            ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profiles-root", "/Users/test/scratch"]),
            "/Users/test/scratch"
        )
    }

    /// The browser-x4l regression: macOS's /tmp is a permanent symlink to
    /// /private/tmp -- a natural scratch path for an agent's test launch to
    /// reach for -- and CEF's own cache_path validation rejects the mismatch
    /// between that symlinked form and the canonical one it resolves
    /// internally, silently falling back to in-memory-only storage. This
    /// must come back already canonicalized so every caller (CEF's
    /// cache_path, session/profile metadata, CLISocketPath's hash) agrees.
    func testExplicitOverrideCanonicalizesASymlinkedTmpPath() {
        XCTAssertEqual(
            ProfilesRootResolver.explicitOverride(arguments: ["Browser", "--profiles-root", "/tmp/scratch"]),
            "/private/tmp/scratch"
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
        // "As-is" modulo canonicalization (browser-x4l) -- /Users/test/scratch
        // has no symlinked component, so this is the same path either way.
        XCTAssertEqual(
            ProfilesRootResolver.profilesRootPath(
                arguments: ["Browser", "--profiles-root", "/Users/test/scratch"], appSupportDirectory: appSupport
            ),
            "/Users/test/scratch"
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
        let arguments = ["Browser", "--profiles-root", "/Users/test/scratch"]
        XCTAssertEqual(
            ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: arguments, appSupportDirectory: appSupport),
            ProfilesRootResolver.profilesRootPath(arguments: arguments, appSupportDirectory: appSupport)
        )
        XCTAssertEqual(
            ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: arguments, appSupportDirectory: appSupport),
            "/Users/test/scratch"
        )
    }

    /// Both of this file's functions resolve through the same
    /// `explicitOverride` -- confirms the canonicalization above isn't
    /// accidentally only applied to one of them.
    func testOverriddenMetadataDirectoryIsAlsoCanonicalizedForASymlinkedPath() {
        let arguments = ["Browser", "--profiles-root", "/tmp/scratch"]
        XCTAssertEqual(
            ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: arguments, appSupportDirectory: appSupport),
            "/private/tmp/scratch"
        )
        XCTAssertEqual(
            ProfilesRootResolver.profilesRootPath(arguments: arguments, appSupportDirectory: appSupport),
            "/private/tmp/scratch"
        )
    }

    // MARK: - testPreferencesSuiteName (browser-xrq)

    func testSuiteNameIsDeterministicForTheSamePath() {
        XCTAssertEqual(
            ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: "/tmp/scratch-1"),
            ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: "/tmp/scratch-1")
        )
    }

    func testSuiteNameDiffersForDifferentPaths() {
        XCTAssertNotEqual(
            ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: "/tmp/scratch-1"),
            ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: "/tmp/scratch-2")
        )
    }

    /// A raw filesystem path has characters ("/", " ", "-") that aren't safe
    /// in a UserDefaults suite name / CFPreferences domain -- every non-
    /// alphanumeric character from the path itself must be replaced, not
    /// just slashes. (The reverse-DNS-style prefix's own dots are expected
    /// and fine -- this only checks the path-derived suffix.)
    func testSuiteNameSanitizesNonAlphanumericCharacters() {
        let suite = ProfilesRootResolver.testPreferencesSuiteName(profilesRootOverride: "/tmp/scratch dir-1")
        let suffix = suite.replacingOccurrences(of: "dev.stroud.browser.testprefs.", with: "")
        XCTAssertFalse(suffix.contains("/"))
        XCTAssertFalse(suffix.contains(" "))
        XCTAssertFalse(suffix.contains("-"))
    }

    // MARK: - profileDirectory (browser-ojw)

    func testProfileDirectoryIsKeyedByIdNotName() {
        XCTAssertEqual(
            ProfilesRootResolver.profileDirectory(profilesRoot: "/tmp/profiles-root", profileId: "ABCD-1234"),
            "/tmp/profiles-root/ABCD-1234"
        )
    }

    func testProfileDirectoryDiffersForDifferentIds() {
        XCTAssertNotEqual(
            ProfilesRootResolver.profileDirectory(profilesRoot: "/tmp/profiles-root", profileId: "id-1"),
            ProfilesRootResolver.profileDirectory(profilesRoot: "/tmp/profiles-root", profileId: "id-2")
        )
    }

    // MARK: - downloadsDirectory (browser-5kq.14)

    /// The whole point: a normal launch must keep writing downloads to the
    /// user's real ~/Downloads, unchanged.
    func testDownloadsDirectoryDefaultsToHomeDownloads() {
        XCTAssertEqual(
            ProfilesRootResolver.downloadsDirectory(arguments: ["Browser"], homeDirectory: "/Users/someone"),
            "/Users/someone/Downloads"
        )
    }

    /// ...and an explicit --profiles-root launch must not, or an agent's
    /// test download lands in Brady's actual Downloads folder.
    func testDownloadsDirectoryIsContainedByExplicitProfilesRoot() {
        XCTAssertEqual(
            ProfilesRootResolver.downloadsDirectory(
                arguments: ["Browser", "--profiles-root", "/tmp/scratch-root"],
                homeDirectory: "/Users/someone"
            ),
            "/private/tmp/scratch-root/Downloads"
        )
    }

    /// A trailing "--profiles-root" with no value is not an override -- it
    /// must fall back to the real home directory rather than resolving to
    /// something like "/Downloads".
    func testDownloadsDirectoryIgnoresValuelessProfilesRootFlag() {
        XCTAssertEqual(
            ProfilesRootResolver.downloadsDirectory(
                arguments: ["Browser", "--profiles-root"], homeDirectory: "/Users/someone"),
            "/Users/someone/Downloads"
        )
    }
}
