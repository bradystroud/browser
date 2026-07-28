import XCTest
@testable import AutofillCore

final class FieldClassifierTests: XCTestCase {
    func testAutocompleteTokensTakePriority() {
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "cc-number", name: "unrelated", id: nil, placeholder: nil), .ccNumber)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "cc-name", name: nil, id: nil, placeholder: nil), .ccName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "cc-exp", name: nil, id: nil, placeholder: nil), .ccExpCombined)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "cc-exp-month", name: nil, id: nil, placeholder: nil), .ccExpMonth)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "cc-exp-year", name: nil, id: nil, placeholder: nil), .ccExpYear)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "cc-csc", name: nil, id: nil, placeholder: nil), .ccCSC)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "street-address", name: nil, id: nil, placeholder: nil), .streetAddress)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "address-line2", name: nil, id: nil, placeholder: nil), .addressLine2)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "address-level1", name: nil, id: nil, placeholder: nil), .addressLevel1)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "address-level2", name: nil, id: nil, placeholder: nil), .addressLevel2)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "postal-code", name: nil, id: nil, placeholder: nil), .postalCode)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "country", name: nil, id: nil, placeholder: nil), .country)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "tel", name: nil, id: nil, placeholder: nil), .tel)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "email", name: nil, id: nil, placeholder: nil), .email)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "given-name", name: nil, id: nil, placeholder: nil), .givenName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "family-name", name: nil, id: nil, placeholder: nil), .familyName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "name", name: nil, id: nil, placeholder: nil), .fullName)
    }

    func testAutocompleteMultipleTokensChecksEachOne() {
        // Per the WHATWG spec, autocomplete can carry multiple space-
        // separated tokens (e.g. a "section" or "shipping"/"billing"
        // prefix) -- every token should be checked, not just the last one.
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "billing cc-number", name: nil, id: nil, placeholder: nil), .ccNumber)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: "shipping street-address", name: nil, id: nil, placeholder: nil), .streetAddress)
    }

    func testFallbackHeuristicsForCardFields() {
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "cardNumber", id: nil, placeholder: nil), .ccNumber)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: nil, id: "card-number-input", placeholder: nil), .ccNumber)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: nil, id: nil, placeholder: "Card number"), .ccNumber)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "nameOnCard", id: nil, placeholder: nil), .ccName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "cc_expiry", id: nil, placeholder: nil), .ccExpCombined)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "exp-month", id: nil, placeholder: nil), .ccExpMonth)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "exp-year", id: nil, placeholder: nil), .ccExpYear)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: nil, id: nil, placeholder: "CVV"), .ccCSC)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "security_code", id: nil, placeholder: nil), .ccCSC)
    }

    func testFallbackHeuristicsForAddressFields() {
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "street_address", id: nil, placeholder: nil), .streetAddress)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "address2", id: nil, placeholder: nil), .addressLine2)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "apt_number", id: nil, placeholder: nil), .addressLine2)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "city", id: nil, placeholder: nil), .addressLevel2)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "state", id: nil, placeholder: nil), .addressLevel1)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "zip_code", id: nil, placeholder: nil), .postalCode)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "country", id: nil, placeholder: nil), .country)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "phone_number", id: nil, placeholder: nil), .tel)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "email_address", id: nil, placeholder: nil), .email)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "first_name", id: nil, placeholder: nil), .givenName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "last_name", id: nil, placeholder: nil), .familyName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "full_name", id: nil, placeholder: nil), .fullName)
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "name", id: nil, placeholder: nil), .fullName)
    }

    func testBareTelSubstringDoesNotFalsePositive() {
        // A known, accepted limitation of substring-based fallback
        // heuristics: matching a bare "tel" would false-positive on
        // "hotel"/"intel"-shaped words, so the fallback only matches
        // fuller phrases ("phone", "mobile", "telephone", "cellphone")
        // rather than the bare autocomplete token "tel" itself (which is
        // still matched exactly via the autocomplete-attribute path).
        XCTAssertNil(FieldClassifier.classify(autocomplete: nil, name: "hotel_name", id: nil, placeholder: nil))
    }

    func testCardNameFieldIsNotMisclassifiedAsFullName() {
        // "card-name" contains "name" but must classify as .ccName, not
        // .fullName -- regression guard for the card-specific checks
        // needing to run before the generic name/address ones.
        XCTAssertEqual(FieldClassifier.classify(autocomplete: nil, name: "card-name", id: nil, placeholder: nil), .ccName)
    }

    func testUnrecognizedFieldReturnsNil() {
        XCTAssertNil(FieldClassifier.classify(autocomplete: nil, name: "search-query", id: "q", placeholder: "Search…"))
        XCTAssertNil(FieldClassifier.classify(autocomplete: nil, name: nil, id: nil, placeholder: nil))
    }

    func testGroupMapping() {
        XCTAssertEqual(FieldClassifier.group(for: .ccNumber), .card)
        XCTAssertEqual(FieldClassifier.group(for: .ccCSC), .card)
        XCTAssertEqual(FieldClassifier.group(for: .streetAddress), .address)
        XCTAssertEqual(FieldClassifier.group(for: .postalCode), .address)
        XCTAssertEqual(FieldClassifier.group(for: .email), .ambiguous)
        XCTAssertEqual(FieldClassifier.group(for: .fullName), .ambiguous)
    }
}
