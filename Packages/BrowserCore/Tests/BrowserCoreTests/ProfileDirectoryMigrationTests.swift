import XCTest
@testable import BrowserCore

/// browser-le4: the rules that decide whether a profile's legacy name-keyed
/// directory gets moved to its id-keyed one. Covered here rather than by
/// launching the app because getting one of these wrong does not degrade a
/// feature -- it detaches a user from their cookies, history and bookmarks.
final class ProfileDirectoryMigrationTests: XCTestCase {
    private let root = "/tmp/profiles-root"
    private let id = "11111111-2222-3333-4444-555555555555"

    /// `directoryExists` stub: only the listed paths exist.
    private func exists(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    func testMovesLegacyDirectoryWhenOnlyTheNameKeyedOneExists() {
        let outcome = ProfileDirectoryMigration.outcome(
            profilesRoot: root, profileId: id, profileName: "Work",
            directoryExists: exists("\(root)/Work")
        )
        XCTAssertEqual(outcome, .move(from: "\(root)/Work", to: "\(root)/\(id)"))
    }

    func testNothingToMigrateWhenNoLegacyDirectoryExists() {
        let outcome = ProfileDirectoryMigration.outcome(
            profilesRoot: root, profileId: id, profileName: "Work",
            directoryExists: exists("\(root)/\(id)")
        )
        XCTAssertEqual(outcome, .nothingToMigrate)
    }

    /// Both layouts present: either could hold the real state, so this is
    /// reported for a human rather than resolved by guessing. Overwriting the
    /// wrong one destroys a profile's entire history.
    func testAmbiguousWhenBothLayoutsExist() {
        let outcome = ProfileDirectoryMigration.outcome(
            profilesRoot: root, profileId: id, profileName: "Work",
            directoryExists: exists("\(root)/Work", "\(root)/\(id)")
        )
        XCTAssertEqual(outcome, .ambiguous(from: "\(root)/Work", to: "\(root)/\(id)"))
    }

    /// A profile whose display name happens to equal its id is already on the
    /// current layout; moving a directory onto itself would just fail.
    func testNameEqualToIdIsNotAMove() {
        let outcome = ProfileDirectoryMigration.outcome(
            profilesRoot: root, profileId: id, profileName: id,
            directoryExists: exists("\(root)/\(id)")
        )
        XCTAssertEqual(outcome, .nothingToMigrate)
    }

    /// Display names are free-form user text. A name that isn't a single path
    /// component could never have produced a legacy directory, and resolves
    /// OUTSIDE the profiles root -- so treating it as a migration source could
    /// only ever move something this app doesn't own.
    func testNamesThatEscapeTheProfilesRootAreNeverMigrationSources() {
        for escaping in ["..", ".", "../../Documents", "Work/Nested", ""] {
            let outcome = ProfileDirectoryMigration.outcome(
                profilesRoot: root, profileId: id, profileName: escaping,
                // Claim every path exists, so only the name rule can reject it.
                directoryExists: { _ in true }
            )
            XCTAssertEqual(
                outcome, .nothingToMigrate,
                "profile name \(escaping.debugDescription) must never be treated as a migration source"
            )
        }
    }
}
