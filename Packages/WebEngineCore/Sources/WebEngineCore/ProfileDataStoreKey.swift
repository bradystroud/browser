import Foundation

/// Derives the `NSUUID` `WKWebsiteDataStore(forIdentifier:)` needs from this
/// app's own profile identity (`Profile.id`, always a `UUID().uuidString` --
/// see `ProfileManager.createProfile`), so a WebKit-backed tab gets the same
/// per-profile cookie/storage isolation guarantee a CEF-backed tab gets from
/// its own `CefRequestContext` (browser-n50.2). Pure Foundation, no WebKit
/// dependency, so it's testable via `swift test` -- see
/// WebKitEngineAdapter.swift for where the resulting identifier actually
/// gets passed to `WKWebsiteDataStore`.
public enum ProfileDataStoreKey {
    /// The common case: `profileId` already *is* a valid UUID string, so
    /// this is just a parse. Falls back to `deterministicUUID(from:)` rather
    /// than a random/nil identifier if it somehow isn't -- two calls for the
    /// same profile id must always resolve to the same data store, or that
    /// profile's cookies/storage would silently reset on every relaunch.
    public static func identifier(forProfileId profileId: String) -> UUID {
        if let uuid = UUID(uuidString: profileId) {
            return uuid
        }
        return deterministicUUID(from: profileId)
    }

    /// A stable UUID derived from `seed` by hashing -- deliberately *not*
    /// `UUID()` (random) or Swift's own `Hashable`/`Hasher` (per-process
    /// randomized seed, by design, for DoS resistance -- see `Hasher`'s own
    /// documentation), since either would give a different identifier every
    /// launch. Two 64-bit FNV-1a passes with different offset bases build
    /// the 16 bytes a UUID needs; this is a defensive fallback only (see
    /// `identifier(forProfileId:)` above), not the common path, so
    /// collision resistance beyond "stable and well-distributed" doesn't
    /// need a cryptographic hash here.
    static func deterministicUUID(from seed: String) -> UUID {
        let bytes = Array(seed.utf8)
        let high = fnv1a64(bytes, offsetBasis: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a64(bytes, offsetBasis: 0x9e37_79b9_7f4a_7c15)

        var uuidBytes = [UInt8]()
        uuidBytes.reserveCapacity(16)
        withUnsafeBytes(of: high.bigEndian) { uuidBytes.append(contentsOf: $0) }
        withUnsafeBytes(of: low.bigEndian) { uuidBytes.append(contentsOf: $0) }

        return uuidBytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress!) as UUID
        }
    }

    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    private static func fnv1a64(_ bytes: [UInt8], offsetBasis: UInt64) -> UInt64 {
        var hash = offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }
}
