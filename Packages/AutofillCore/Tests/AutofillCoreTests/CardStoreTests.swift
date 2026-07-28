import XCTest
@testable import AutofillCore

/// Exercises real Keychain access (not mocked) -- same reasoning as
/// PasswordStore's own verification: this is the only way to actually
/// prove the kSecAttrGeneric/kSecAttrAccount/kSecAttrService schema choices
/// round-trip and stay correctly scoped, which is exactly the class of bug
/// PasswordStore's kSecAttrService-on-InternetPassword mistake was. Uses a
/// unique, throwaway profile name per test run so it can never collide
/// with a real saved card, and cleans up everything it creates in
/// tearDown regardless of whether the test passed or failed.
final class CardStoreTests: XCTestCase {
    private var profileName = ""
    private var createdIds: [String] = []

    override func setUp() {
        super.setUp()
        profileName = "autofillcore-test-\(UUID().uuidString)"
        createdIds = []
    }

    override func tearDown() {
        for id in createdIds {
            CardStore.delete(profileName: profileName, id: id)
        }
        super.tearDown()
    }

    func testSaveAndReadRoundTrip() {
        guard let id = CardStore.save(
            profileName: profileName, cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242", expMonth: 4, expYear: 2029
        ) else {
            return XCTFail("save should succeed")
        }
        createdIds.append(id)

        let number = CardStore.cardNumber(profileName: profileName, id: id)
        XCTAssertEqual(number, "4242424242424242")
    }

    func testAllCardsNeverIncludesTheNumber() {
        guard let id = CardStore.save(
            profileName: profileName, cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242", expMonth: 4, expYear: 2029
        ) else {
            return XCTFail("save should succeed")
        }
        createdIds.append(id)

        let cards = CardStore.allCards(profileName: profileName)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.cardholderName, "Ada Lovelace")
        XCTAssertEqual(cards.first?.last4, "4242")
        XCTAssertEqual(cards.first?.expMonth, 4)
        XCTAssertEqual(cards.first?.expYear, 2029)
    }

    func testAllCardsIsScopedToItsOwnProfile() {
        guard let id = CardStore.save(
            profileName: profileName, cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242", expMonth: 4, expYear: 2029
        ) else {
            return XCTFail("save should succeed")
        }
        createdIds.append(id)

        let otherProfile = "autofillcore-test-\(UUID().uuidString)"
        // Regression guard for exactly the bug PasswordStore's own notes
        // document: a query scoped by an attribute that isn't real for this
        // item class would silently return every card in the whole
        // keychain here, not just this profile's one.
        XCTAssertTrue(CardStore.allCards(profileName: otherProfile).isEmpty)
    }

    func testDeleteRemovesTheCard() {
        guard let id = CardStore.save(
            profileName: profileName, cardholderName: "Ada Lovelace",
            cardNumber: "4242424242424242", expMonth: 4, expYear: 2029
        ) else {
            return XCTFail("save should succeed")
        }
        createdIds.append(id)

        XCTAssertTrue(CardStore.delete(profileName: profileName, id: id))
        XCTAssertNil(CardStore.cardNumber(profileName: profileName, id: id))
        XCTAssertTrue(CardStore.allCards(profileName: profileName).isEmpty)
    }

    func testSavingWithSameIdOverwrites() {
        let id = UUID().uuidString
        createdIds.append(id)
        CardStore.save(profileName: profileName, id: id, cardholderName: "Ada Lovelace", cardNumber: "4242424242424242", expMonth: 4, expYear: 2029)
        CardStore.save(profileName: profileName, id: id, cardholderName: "Ada Lovelace", cardNumber: "5555555555554444", expMonth: 11, expYear: 2030)

        let cards = CardStore.allCards(profileName: profileName)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.last4, "4444")
        XCTAssertEqual(CardStore.cardNumber(profileName: profileName, id: id), "5555555555554444")
    }
}
