import Foundation

/// The Keychain namespace a launch's saved passwords and cards live in.
///
/// The login Keychain is one per user, not one per `--profiles-root`, so
/// without this a scratch instance saw, overwrote and deleted the real
/// install's items: they were keyed by profile name alone, and every
/// instance has a profile called "default". A normal launch keeps exactly
/// the identity items have always had (an empty qualifier), so nothing
/// needs migrating; a launch with `--profiles-root` gets a qualifier derived
/// from its canonical root path -- the same root always maps to the same
/// items across launches, a different root never to another's.
///
/// The qualifier is spliced in *before* the separator that precedes the
/// profile name ("...password-scratch-<hash>.<profile>" rather than
/// "...password.<profile>"), so no real profile name, whatever it contains,
/// can produce a scratch namespace or the other way round.
public enum KeychainNamespace {
    /// "" for the real install, "-scratch-<16 hex digits>" for any other
    /// profiles root.
    public static func qualifier(profilesRootOverride: String?) -> String {
        guard let root = profilesRootOverride else { return "" }
        return "-scratch-" + stableHash(root)
    }

    /// This process's qualifier, from its own `--profiles-root` argument.
    public static let current = qualifier(
        profilesRootOverride: ProfilesRootResolver.explicitOverride(arguments: ProcessInfo.processInfo.arguments))

    /// PasswordStore's `kSecAttrSecurityDomain`.
    public static func passwordSecurityDomain(profileName: String, qualifier: String = current) -> String {
        "dev.stroud.browser.password\(qualifier).\(profileName)"
    }

    /// CardStore's `kSecAttrService`.
    public static func cardService(profileName: String, qualifier: String = current) -> String {
        "dev.stroud.browser.card\(qualifier).\(profileName)"
    }

    /// 64-bit FNV-1a over the path's UTF-8 bytes. Deterministic across
    /// launches, unlike Swift's seeded `hashValue`.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
