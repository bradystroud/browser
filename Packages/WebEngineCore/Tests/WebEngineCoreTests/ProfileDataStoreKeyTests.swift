import XCTest
@testable import WebEngineCore

final class ProfileDataStoreKeyTests: XCTestCase {
    func testValidUUIDStringRoundTrips() {
        let id = UUID()
        XCTAssertEqual(ProfileDataStoreKey.identifier(forProfileId: id.uuidString), id)
    }

    func testValidUUIDStringIsCaseInsensitive() {
        let id = UUID()
        XCTAssertEqual(ProfileDataStoreKey.identifier(forProfileId: id.uuidString.lowercased()), id)
    }

    func testNonUUIDInputIsStableAcrossCalls() {
        let first = ProfileDataStoreKey.identifier(forProfileId: "not-a-uuid")
        let second = ProfileDataStoreKey.identifier(forProfileId: "not-a-uuid")
        XCTAssertEqual(first, second)
    }

    func testDifferentNonUUIDInputsProduceDifferentIdentifiers() {
        let a = ProfileDataStoreKey.identifier(forProfileId: "profile-a")
        let b = ProfileDataStoreKey.identifier(forProfileId: "profile-b")
        XCTAssertNotEqual(a, b)
    }

    func testEmptyStringDoesNotCrashAndIsStable() {
        let first = ProfileDataStoreKey.identifier(forProfileId: "")
        let second = ProfileDataStoreKey.identifier(forProfileId: "")
        XCTAssertEqual(first, second)
    }

    func testDeterministicUUIDDirectly() {
        let a = ProfileDataStoreKey.deterministicUUID(from: "seed")
        let b = ProfileDataStoreKey.deterministicUUID(from: "seed")
        let c = ProfileDataStoreKey.deterministicUUID(from: "different-seed")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
