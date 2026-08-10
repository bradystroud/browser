import Foundation
import Security

/// A saved card's non-secret display info -- cardholder name, last 4
/// digits, expiry -- never the full card number. See
/// `CardStore.cardNumber(profileName:id:)` for the one place that's read
/// back.
public struct StoredCardSummary: Equatable, Sendable {
    public let id: String
    public let cardholderName: String
    public let last4: String
    public let expMonth: Int
    public let expYear: Int

    public init(id: String, cardholderName: String, last4: String, expMonth: Int, expYear: Int) {
        self.id = id
        self.cardholderName = cardholderName
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
    }
}

/// Non-secret companion metadata stored alongside the card number, so
/// listing cards (for the Settings pane) never needs to touch/decrypt
/// `kSecValueData` at all -- `kSecAttrGeneric` is returned by
/// `SecItemCopyMatching`'s `kSecReturnAttributes` just like any other
/// attribute, with no ACL/decryption step, exactly like `PasswordStore`'s
/// `allCredentials()` never touching its items' `kSecValueData` either.
private struct CardMetadata: Codable {
    let cardholderName: String
    let last4: String
    let expMonth: Int
    let expYear: Int
}

/// Per-profile, Keychain-backed card storage (browser-ojh.2). NEVER stores
/// the card verification code (CVV/CVC/CSC) -- there is no field for it
/// anywhere in this type or its Keychain item shape, deliberately, so
/// there's no accidental path to persisting one even by mistake. The user
/// always types their CVC themselves; this store (and the autofill script
/// that reads from it) never fills or remembers it.
///
/// Uses `kSecClassGenericPassword`, NOT `kSecClassInternetPassword` --
/// unlike PasswordStore (which stores real website logins under
/// InternetPassword, matching how Safari/Chrome themselves model a saved
/// site login), a card isn't tied to a URL/server at all, and
/// GenericPassword's schema is the one built around an opaque
/// account+service pair, which is exactly what's needed here:
///   - kSecAttrAccount = this card's own generated id (a UUID string) --
///     the primary key distinguishing one saved card from another.
///   - kSecAttrService = "dev.stroud.browser.card.<profileName>" -- this
///     app's own namespace, one per profile, so two profiles never see
///     each other's saved cards.
///   - kSecAttrGeneric = JSON-encoded CardMetadata (cardholder name, last 4
///     digits, expiry) -- both kSecAttrAccount and kSecAttrService above,
///     *and* kSecAttrGeneric, are genuinely part of kSecClassGenericPassword's
///     documented schema (unlike PasswordStore's original kSecAttrService
///     mistake on InternetPassword items -- see that store's own doc
///     comment for the bug that taught this lesson, and why every attribute
///     used for scoping/querying here is double-checked against the actual
///     item class's schema before being relied on).
///   - kSecValueData = the actual card number, UTF-8 encoded -- the one
///     secret this store protects.
public enum CardStore {
    private static func service(profileName: String) -> String {
        "dev.stroud.browser.card.\(profileName)"
    }

    /// Saves a new card, or overwrites an existing one if `id` matches one
    /// already saved (same delete-then-add approach as PasswordStore.save,
    /// for the same reason -- this is a whole-item overwrite, not an
    /// incremental attribute patch). Returns the id the card was saved
    /// under (either the one passed in, or a freshly generated one).
    @discardableResult
    public static func save(
        profileName: String, id: String = UUID().uuidString,
        cardholderName: String, cardNumber: String, expMonth: Int, expYear: Int
    ) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: service(profileName: profileName),
        ]
        SecItemDelete(query as CFDictionary)

        let metadata = CardMetadata(
            cardholderName: cardholderName,
            last4: String(cardNumber.suffix(4)),
            expMonth: expMonth, expYear: expYear
        )
        guard let metadataData = try? JSONEncoder().encode(metadata) else { return nil }

        var addQuery = query
        addQuery[kSecValueData as String] = Data(cardNumber.utf8)
        addQuery[kSecAttrGeneric as String] = metadataData
        addQuery[kSecAttrLabel as String] = "\(profileName): \(cardholderName) ····\(metadata.last4)"
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { return nil }
        postDidChange()
        return id
    }

    /// Always delivered on the main thread -- `save`/`delete` may be called
    /// from a background queue (the app keeps blocking Keychain calls off the
    /// main thread; see browser-le4.1), and every observer of this
    /// notification is UI-layer state.
    private static func postDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .cardStoreDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cardStoreDidChange, object: nil)
            }
        }
    }

    /// Every saved card's non-secret summary in this profile, for the
    /// Settings pane's list and for autofill's "does a card exist" check --
    /// never includes the card number itself.
    public static func allCards(profileName: String) -> [StoredCardSummary] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(profileName: profileName),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else {
            return []
        }
        return items.compactMap { item in
            guard let id = item[kSecAttrAccount as String] as? String,
                  let genericData = item[kSecAttrGeneric as String] as? Data,
                  let metadata = try? JSONDecoder().decode(CardMetadata.self, from: genericData)
            else {
                return nil
            }
            return StoredCardSummary(
                id: id, cardholderName: metadata.cardholderName,
                last4: metadata.last4, expMonth: metadata.expMonth, expYear: metadata.expYear
            )
        }
    }

    /// Reads back a single card's plaintext number -- the only function in
    /// this store that does. Callers (autofill's fill script, and the
    /// Settings pane's "Reveal" action) must gate this behind a fresh
    /// LocalAuthentication check first, same as
    /// `PasswordStore.password(profileName:origin:username:)`.
    public static func cardNumber(profileName: String, id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: service(profileName: profileName),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let number = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return number
    }

    @discardableResult
    public static func delete(profileName: String, id: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id,
            kSecAttrService as String: service(profileName: profileName),
        ]
        let status = SecItemDelete(query as CFDictionary)
        let deleted = status == errSecSuccess || status == errSecItemNotFound
        if deleted {
            postDidChange()
        }
        return deleted
    }
}

extension Notification.Name {
    /// Posted after any successful CardStore write. Callers that cache card
    /// summaries to keep Keychain reads off the main thread (see
    /// browser-le4.1) use this to know when a cached answer is stale.
    public static let cardStoreDidChange = Notification.Name("dev.stroud.browser.cardStoreDidChange")
}
