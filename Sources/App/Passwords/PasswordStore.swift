import Foundation
import Security

/// One saved credential, as listed in the Passwords settings pane -- never
/// carries the password itself (see PasswordStore.password(profileName:
/// origin:username:) for the one place that's read back, gated by Touch ID).
struct SavedCredential: Equatable {
    let origin: String
    let username: String
}

/// Per-profile, Keychain-backed credential storage (browser-ojh.1). NEVER
/// plaintext -- every credential is a real `kSecClassInternetPassword`
/// Keychain item, one per (profile, origin host, username):
///   - kSecAttrServer = the origin's *host* only (no scheme/port) -- per
///     spec, so e.g. an http and https login on the same host share one
///     saved credential (matches how this app's own profile-scoped cookie
///     jars already treat a site, and avoids prompting twice through an
///     HTTP -> HTTPS upgrade redirect).
///   - kSecAttrAccount = username.
///   - kSecAttrSecurityDomain = "dev.stroud.browser.password.<profileName>" --
///     this app's own namespace, one per profile, so two profiles never see
///     each other's saved credentials (matches history/bookmarks/downloads/
///     cookies' existing per-profile isolation). NOT kSecAttrService: that
///     attribute belongs to kSecClassGenericPassword's schema, not
///     kSecClassInternetPassword's -- setting it on an InternetPassword item
///     is silently accepted by SecItemAdd but never actually persisted/
///     matched as a real distinguishing attribute, so a query that includes
///     it doesn't filter by it at all. Confirmed the hard way during this
///     feature's own testing: an early version of this file used
///     kSecAttrService for profile scoping, and allCredentials(profileName:)
///     came back with *every* kSecClassInternetPassword item in the user's
///     real login keychain -- GitHub, Parallels, an unrelated local-dev
///     entry, none of them this app's -- because the service constraint was
///     silently ignored by SecItemCopyMatching. kSecAttrSecurityDomain *is*
///     part of InternetPassword's real primary-key attribute set (alongside
///     server/account/protocol/authenticationType/port/path), so repurposing
///     it as an opaque profile-scoping string actually participates in
///     matching. It has no bearing on this app's own HTTP-auth handling
///     (there is none) so repurposing it is safe.
///   - kSecAttrLabel = "<profileName>: <origin host>" -- human-readable,
///     shown by Keychain Access.app; not used in any query below, so
///     changing its format later (e.g. for the Settings pane) can't break
///     lookups.
///
/// ACL: no explicit kSecAttrAccessible override, so items get Keychain's own
/// default (accessible after first unlock, this app only via its code
/// signature) -- see docs/ai-tasks/password-manager-notes.md's Security
/// section for why that default is the right call here rather than a
/// stricter/looser one.
enum PasswordStore {
    private static func securityDomain(profileName: String) -> String {
        "dev.stroud.browser.password.\(profileName)"
    }

    /// `origin` may be a full origin ("https://example.com") or a bare host
    /// -- either way, only the host is ever used as the Keychain server
    /// attribute (see this enum's own doc comment for why).
    private static func host(fromOrigin origin: String) -> String {
        if let parsed = URL(string: origin), let host = parsed.host {
            return host
        }
        return origin
    }

    /// Saves (or overwrites) a credential. Returns whether the Keychain
    /// operation succeeded -- callers should treat a `false` return as "the
    /// save silently failed," since there's no UI-facing recovery for a rare
    /// Keychain-level error in v1.
    @discardableResult
    static func save(profileName: String, origin: String, username: String, password: String) -> Bool {
        let server = host(fromOrigin: origin)
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: username,
            kSecAttrSecurityDomain as String: securityDomain(profileName: profileName),
        ]
        // Delete-then-add rather than SecItemUpdate: this is a single
        // overwrite-the-whole-item operation (password value + label), not
        // an incremental attribute patch, so there's no benefit to update's
        // separate query/attributes-to-change split here.
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = Data(password.utf8)
        addQuery[kSecAttrLabel as String] = "\(profileName): \(server)"
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// The single saved credential for `origin` in this profile, if any --
    /// used by chunk 4's autofill (existence + username, to decide whether
    /// to show the key icon) and by the save-prompt flow (to detect "this is
    /// the same password already saved," so re-submitting an unchanged
    /// login doesn't re-prompt). At most one credential per (profile,
    /// origin) in v1 -- a page with two distinct saved logins for the same
    /// host isn't supported yet (out of scope; see notes' Deviations).
    static func credential(profileName: String, origin: String) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host(fromOrigin: origin),
            kSecAttrSecurityDomain as String: securityDomain(profileName: profileName),
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return (account, password)
    }

    /// Every saved credential across every origin in this profile, for the
    /// Passwords settings pane's list -- never includes the password itself;
    /// see `password(profileName:origin:username:)` for the one Touch-ID-
    /// gated path that reads it back.
    static func allCredentials(profileName: String) -> [SavedCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain(profileName: profileName),
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
            guard let server = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String
            else { return nil }
            return SavedCredential(origin: server, username: account)
        }
    }

    /// Reads back a single credential's plaintext password -- the only
    /// function in this store that does. Callers (the Settings pane's
    /// "reveal" action) must gate this behind a fresh LocalAuthentication
    /// (Touch ID) check first; this function itself performs no such check,
    /// since Keychain's own ACL (no explicit access-control flags set at
    /// save time) doesn't require per-read authentication -- the UI-level
    /// gate is this app's own, on top of Keychain's default protection.
    static func password(profileName: String, origin: String, username: String) -> String? {
        guard let found = credential(profileName: profileName, origin: origin), found.username == username else {
            return nil
        }
        return found.password
    }

    @discardableResult
    static func delete(profileName: String, origin: String, username: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host(fromOrigin: origin),
            kSecAttrAccount as String: username,
            kSecAttrSecurityDomain as String: securityDomain(profileName: profileName),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
