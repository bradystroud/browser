import Foundation
import Security

extension Notification.Name {
    /// Posted after any successful PasswordStore write (save or delete).
    /// PasswordManagerCoordinator caches Keychain lookups (they happen on a
    /// 0.5s poll and a blocking Keychain call must never reach the main
    /// thread -- see browser-le4.1), so it needs to know when a cached
    /// answer has gone stale.
    static let passwordStoreDidChange = Notification.Name("dev.stroud.browser.passwordStoreDidChange")
}

/// One saved credential, as listed in the Passwords settings pane -- never
/// carries the password itself (see PasswordStore.password(profileName:
/// credential:) for the one place that's read back, gated by Touch ID).
struct SavedCredential: Equatable {
    let scope: CredentialScope
    let username: String

    /// What the pane shows in its Site column.
    var origin: String { scope.displayName }
}

/// Per-profile, Keychain-backed credential storage (browser-ojh.1). NEVER
/// plaintext -- every credential is a real `kSecClassInternetPassword`
/// Keychain item, one per (profile, origin, username):
///   - kSecAttrServer = the origin's host.
///   - kSecAttrProtocol + kSecAttrPort = the origin's scheme and effective
///     port, so an https login is never offered to http on the same host,
///     nor to another port. Items saved before these were recorded carry
///     neither; CredentialScope.legacyHost decides where those may be used,
///     and they are read as they are, never rewritten.
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
    /// Scoped to this launch's --profiles-root as well as the profile; see
    /// KeychainNamespace.
    private static func securityDomain(profileName: String) -> String {
        KeychainNamespace.passwordSecurityDomain(profileName: profileName)
    }

    private static func keychainProtocol(forScheme scheme: String) -> CFString? {
        switch scheme {
        case "https": return kSecAttrProtocolHTTPS
        case "http": return kSecAttrProtocolHTTP
        default: return nil
        }
    }

    /// The scope an item was saved under, from its own attributes. An item
    /// with no protocol attribute predates origin scoping; one with a
    /// protocol this app never writes is ignored.
    private static func scope(ofItem item: [String: Any], server: String) -> CredentialScope? {
        guard let proto = item[kSecAttrProtocol as String] as? String, !proto.isEmpty else {
            return .legacyHost(server)
        }
        let scheme: String
        if proto == kSecAttrProtocolHTTPS as String {
            scheme = "https"
        } else if proto == kSecAttrProtocolHTTP as String {
            scheme = "http"
        } else {
            return nil
        }
        let port = (item[kSecAttrPort as String] as? NSNumber)?.intValue
        return WebOrigin(scheme: scheme, host: server, port: port).map(CredentialScope.origin)
    }

    private struct Item {
        let scope: CredentialScope
        let username: String
        let persistentRef: Data
    }

    /// Every item for this profile (narrowed to `server`/`username` when
    /// given), with the attributes needed to decide which may be used
    /// where -- no secrets.
    private static func items(profileName: String, server: String?, username: String? = nil) -> [Item] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain(profileName: profileName),
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let server { query[kSecAttrServer as String] = server }
        if let username { query[kSecAttrAccount as String] = username }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let found = result as? [[String: Any]]
        else { return [] }
        return found.compactMap { item in
            guard let itemServer = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String,
                  let ref = item[kSecValuePersistentRef as String] as? Data,
                  let scope = scope(ofItem: item, server: itemServer)
            else { return nil }
            return Item(scope: scope, username: account, persistentRef: ref)
        }
    }

    private static func password(persistentRef: Data) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: persistentRef,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func deleteItem(persistentRef: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecValuePersistentRef as String: persistentRef,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Saves (or overwrites) the credential for exactly `origin`. Returns
    /// whether the Keychain operation succeeded -- callers should treat a
    /// `false` return as "the save silently failed," since there's no
    /// UI-facing recovery for a rare Keychain-level error in v1.
    ///
    /// Replaces this username's item for the same origin and, when it
    /// covers this origin's pages, the username's legacy host-only item --
    /// otherwise the superseded password would linger in the list and could
    /// still be filled on the pages the new one doesn't cover.
    @discardableResult
    static func save(profileName: String, origin: WebOrigin, username: String, password: String) -> Bool {
        guard let proto = keychainProtocol(forScheme: origin.scheme) else { return false }
        for item in items(profileName: profileName, server: origin.host, username: username)
        where item.scope == .origin(origin) || (item.scope == .legacyHost(origin.host) && item.scope.matches(origin)) {
            deleteItem(persistentRef: item.persistentRef)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin.host,
            kSecAttrProtocol as String: proto,
            kSecAttrPort as String: origin.port,
            kSecAttrAccount as String: username,
            kSecAttrSecurityDomain as String: securityDomain(profileName: profileName),
            kSecValueData as String: Data(password.utf8),
            kSecAttrLabel as String: "\(profileName): \(origin.host)",
        ]
        let saved = SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        if saved {
            postDidChange()
        }
        return saved
    }

    /// Always delivered on the main thread -- `save`/`delete` may be called
    /// from the background queue PasswordManagerCoordinator uses to keep
    /// blocking Keychain calls off the main thread, and every observer of
    /// this notification is UI-layer state.
    private static func postDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .passwordStoreDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .passwordStoreDidChange, object: nil)
            }
        }
    }

    /// The saved credential that may be used on a page at `origin`, if any
    /// (CredentialScope decides) -- used by autofill (existence + username,
    /// to decide whether to show the key icon) and by the save-prompt flow
    /// (to detect "this is the same password already saved," so
    /// re-submitting an unchanged login doesn't re-prompt). At most one
    /// credential per (profile, origin) in v1 -- a page with two distinct
    /// saved logins for the same site isn't supported yet (out of scope;
    /// see notes' Deviations).
    static func credential(profileName: String, for origin: WebOrigin) -> (username: String, password: String)? {
        let candidates = items(profileName: profileName, server: origin.host)
        guard let best = CredentialScope.bestMatch(for: origin, in: candidates, scope: { $0.scope }),
              let password = password(persistentRef: best.persistentRef)
        else { return nil }
        return (best.username, password)
    }

    /// Every saved credential across every origin in this profile, for the
    /// Passwords settings pane's list -- never includes the password itself;
    /// see `password(profileName:credential:)` for the one Touch-ID-gated
    /// path that reads it back.
    static func allCredentials(profileName: String) -> [SavedCredential] {
        items(profileName: profileName, server: nil).map { SavedCredential(scope: $0.scope, username: $0.username) }
    }

    private static func item(profileName: String, credential: SavedCredential) -> Item? {
        let server: String
        switch credential.scope {
        case .origin(let origin): server = origin.host
        case .legacyHost(let host): server = host
        }
        return items(profileName: profileName, server: server, username: credential.username)
            .first { $0.scope == credential.scope }
    }

    /// Reads back a single credential's plaintext password for the
    /// Settings pane's "reveal" action, which must gate this behind a fresh
    /// LocalAuthentication (Touch ID) check first; this function itself
    /// performs no such check, since Keychain's own ACL (no explicit
    /// access-control flags set at save time) doesn't require per-read
    /// authentication -- the UI-level gate is this app's own, on top of
    /// Keychain's default protection.
    static func password(profileName: String, credential: SavedCredential) -> String? {
        item(profileName: profileName, credential: credential).flatMap { password(persistentRef: $0.persistentRef) }
    }

    @discardableResult
    static func delete(profileName: String, credential: SavedCredential) -> Bool {
        guard let item = item(profileName: profileName, credential: credential) else { return true }
        let deleted = deleteItem(persistentRef: item.persistentRef)
        if deleted {
            postDidChange()
        }
        return deleted
    }
}
