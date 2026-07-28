import Foundation

/// What a single `<input>` (or similar) field looks like it's for, based on
/// its `autocomplete` token first and a name/id/placeholder heuristic as
/// fallback (browser-ojh.2). This is the canonical, unit-tested version of
/// the classification rules; PaymentAddressDetectionScript.swift's injected
/// JS implements the *same* rules by hand for use inside the page (a
/// `<script>` can't call into this Swift package directly), so the two are
/// kept in sync manually, not literally shared code the way RoutingCore/
/// BrowserCore/BlockListCore's Swift files are compiled into both a
/// standalone package and the app target -- any change here should have a
/// matching change made there, and vice versa.
public enum DetectedFieldKind: Equatable, Sendable {
    case ccNumber
    case ccName
    case ccExpMonth
    case ccExpYear
    /// A single combined "MM/YY" (or similar) expiry field, as opposed to
    /// separate month/year fields.
    case ccExpCombined
    /// Card verification code -- CVV/CVC/CSC. Recognized so the fill script
    /// can deliberately *skip* it, never so it can be filled: this app
    /// never stores a CSC value (see CardStore's own doc comment), and
    /// never fills one even if a page's autofill happened to have one --
    /// the user always types it themselves.
    case ccCSC
    case streetAddress
    case addressLine2
    /// State/province/region ("address-level1" in the autocomplete spec).
    case addressLevel1
    /// City/town ("address-level2").
    case addressLevel2
    case postalCode
    case country
    case tel
    case email
    case givenName
    case familyName
    case fullName
}

/// Which stored-data group a detected field kind belongs to -- used by the
/// injected script to decide whether a `<form>` containing this field looks
/// like a payment form or an address form (a field with an ambiguous kind
/// like `.email`/`.tel`/`.fullName` can appear in either, so that decision
/// also looks at what *other* fields the same form has -- see
/// PaymentAddressDetectionScript's own doc comment for that grouping logic,
/// which isn't expressed here since it's a whole-form question, not a
/// single-field one).
public enum AutofillGroup: Equatable, Sendable {
    case card
    case address
    /// Could belong to either a card or an address form on its own --
    /// `.email`, `.tel`, `.givenName`, `.familyName`, `.fullName`.
    case ambiguous
}

public enum FieldClassifier {
    /// Exact `autocomplete` token matches, per the WHATWG autocomplete
    /// attribute spec -- checked before any name/id/placeholder heuristic,
    /// since a page that bothered to set this attribute correctly is by far
    /// the most reliable signal available.
    private static let autocompleteTokens: [String: DetectedFieldKind] = [
        "cc-number": .ccNumber,
        "cc-name": .ccName,
        "cc-given-name": .ccName,
        "cc-additional-name": .ccName,
        "cc-family-name": .ccName,
        "cc-exp": .ccExpCombined,
        "cc-exp-month": .ccExpMonth,
        "cc-exp-year": .ccExpYear,
        "cc-csc": .ccCSC,
        "street-address": .streetAddress,
        "address-line1": .streetAddress,
        "address-line2": .addressLine2,
        "address-level1": .addressLevel1,
        "address-level2": .addressLevel2,
        "postal-code": .postalCode,
        "country": .country,
        "country-name": .country,
        "tel": .tel,
        "tel-national": .tel,
        "email": .email,
        "given-name": .givenName,
        "family-name": .familyName,
        "name": .fullName,
    ]

    /// Classifies one field from its own attributes. `autocomplete` may
    /// contain multiple space-separated tokens (e.g. "shipping cc-number")
    /// per the spec -- every token is checked, not just the last one, since
    /// real-world markup is inconsistent about ordering; the first
    /// recognized token wins. Falls back to a name/id/placeholder substring
    /// heuristic (case-insensitive) when `autocomplete` is absent or
    /// unrecognized. Returns nil if nothing matches -- most fields on most
    /// forms (submit buttons, unrelated inputs, etc.) should classify as
    /// nil.
    public static func classify(autocomplete: String?, name: String?, id: String?, placeholder: String?) -> DetectedFieldKind? {
        if let autocomplete {
            for token in autocomplete.lowercased().split(separator: " ") {
                if let kind = autocompleteTokens[String(token)] {
                    return kind
                }
            }
        }
        let haystack = [name, id, placeholder].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !haystack.isEmpty else { return nil }
        return classifyByHeuristic(haystack)
    }

    private static func classifyByHeuristic(_ haystack: String) -> DetectedFieldKind? {
        // Every separator (-, _, space, /) collapsed away before matching,
        // so "full_name", "full-name", "full name", and "fullname" (and
        // "MM/YY" vs "mm yy") all normalize to the same thing -- one term
        // per concept below, instead of needing every separator variant
        // enumerated by hand (a real gap the first version of this
        // function had: "security_code" and "full_name" both slipped
        // through because only some of their separator variants were
        // listed).
        let compact = haystack.filter { $0.isLetter || $0.isNumber }
        func contains(_ needles: String...) -> Bool {
            needles.contains { compact.contains($0) }
        }
        // Short abbreviations ("fname", "lname") are too promiscuous to
        // check as substrings of `compact` -- "lname" alone is a substring
        // of both "fullname" and "hotelname" purely by coincidence of
        // spelling. These are only ever real field-name *words* on their
        // own (a form author writes a field literally called "fname", not
        // a longer word that happens to contain it), so they're checked as
        // exact whole tokens instead, split on any non-alphanumeric
        // separator (this is why "full_name" and "hotel_name" don't
        // wrongly match "fname"/"lname" but a field actually named
        // `fname`/`f_name`/`f-name` does).
        let tokens = Set(haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func hasToken(_ needles: String...) -> Bool {
            needles.contains { tokens.contains($0) }
        }

        // Card-specific checks first -- "card" + "number" is unambiguous,
        // and CSC/CVV wording never legitimately overlaps with an address
        // field's, so order relative to the address checks below doesn't
        // matter, but checking these first keeps a field like "card-name"
        // (which also contains "name") from being misclassified as
        // .fullName by the identity checks further down.
        if contains("cvv", "cvc", "csc", "securitycode", "cardverification") {
            return .ccCSC
        }
        if contains("cardnumber", "ccnum") || (contains("card") && contains("number")) {
            return .ccNumber
        }
        if contains("nameoncard", "cardholder") || (contains("card") && contains("name")) {
            return .ccName
        }
        if contains("expmonth", "expirymonth") {
            return .ccExpMonth
        }
        if contains("expyear", "expiryyear") {
            return .ccExpYear
        }
        if contains("expiry", "expdate", "cardexp", "ccexp", "mmyy") {
            return .ccExpCombined
        }

        // Identity/contact checks before the broader address ones below --
        // "email" and "phone" are specific enough to check first, since
        // e.g. "email_address" would otherwise match the generic "address"
        // fallback for .streetAddress before ever reaching the .email
        // check.
        if contains("email") {
            return .email
        }
        if contains("phone", "mobile", "cellphone", "telephone") {
            return .tel
        }
        if contains("country") {
            return .country
        }

        // Address checks, broadest ("address"/"street" alone) last among
        // them, since more specific terms (line 2, city, state, postal)
        // should win if present.
        if contains("address2", "addr2", "apt", "suite", "unit") {
            return .addressLine2
        }
        if contains("city", "town") {
            return .addressLevel2
        }
        if contains("state", "province", "region") {
            return .addressLevel1
        }
        if contains("zip", "postal") {
            return .postalCode
        }
        if contains("street", "address1", "addr1", "address") {
            return .streetAddress
        }

        if contains("firstname", "givenname") || hasToken("fname") {
            return .givenName
        }
        if contains("lastname", "surname", "familyname") || hasToken("lname") {
            return .familyName
        }
        if contains("fullname") || compact == "name" {
            return .fullName
        }
        return nil
    }

    /// Which stored-data group `kind` unambiguously belongs to, if any --
    /// see AutofillGroup's own doc comment for why some kinds are
    /// `.ambiguous` instead.
    public static func group(for kind: DetectedFieldKind) -> AutofillGroup {
        switch kind {
        case .ccNumber, .ccName, .ccExpMonth, .ccExpYear, .ccExpCombined, .ccCSC:
            return .card
        case .streetAddress, .addressLine2, .addressLevel1, .addressLevel2, .postalCode, .country:
            return .address
        case .tel, .email, .givenName, .familyName, .fullName:
            return .ambiguous
        }
    }
}
