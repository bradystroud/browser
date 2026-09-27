import Foundation

/// Writes parsed CSV password entries into PasswordStore (browser-ymx),
/// deduped by (origin, username) -- an existing saved credential wins
/// unless the caller opts to overwrite. Pure Keychain/PasswordStore glue,
/// no UI; called by SafariImportWindowController's CSV section and by
/// ChromiumImportWindowController.
///
/// SECURITY, non-negotiable (per Brady's own explicit requirement for this
/// feature):
///   - Never log a password, not even truncated, not even behind a debug
///     flag. Nothing in this file (or PasswordCSVParser, which produces the
///     values consumed here) calls print/NSLog/os_log on any credential.
///   - Hold a decrypted/plaintext password in memory only as long as it
///     takes to hand it to PasswordStore.save(_:) -- this function doesn't
///     retain the `entries` array or copy any individual password anywhere
///     beyond the single call each one flows through.
enum PasswordImportCoordinator {
    struct ImportResult {
        let importedCount: Int
        let skippedAsDuplicateCount: Int
        /// Rows with no http(s) origin or no username.
        let unusableCount: Int
        /// Rows the Keychain refused to save.
        let failedCount: Int
    }

    /// `overwriteExisting`: when false (the default UI choice), an entry
    /// whose (origin, username) already has a saved credential in `profile`
    /// is skipped rather than replacing it -- "existing entry wins," per
    /// Brady's own spec.
    static func importEntries(_ entries: [PasswordCSVEntry], into profile: Profile, overwriteExisting: Bool) -> ImportResult {
        struct Key: Hashable {
            let scope: CredentialScope
            let username: String
        }

        // One allCredentials() read up front rather than one Keychain
        // query per row -- this set is kept up to date as rows are
        // imported below, so a CSV with duplicate rows for the same
        // (origin, username) still dedupes correctly against itself, not
        // just against what was already saved before this import started.
        var existing = Set(PasswordStore.allCredentials(profileName: profile.name).map { Key(scope: $0.scope, username: $0.username) })

        var imported = 0
        var skipped = 0
        var unusable = 0
        var failed = 0
        for entry in entries {
            // A row with no http(s) origin (an android:// app entry, say)
            // could never be filled into a web page.
            guard let origin = WebOrigin(urlString: entry.url), !entry.username.isEmpty else {
                unusable += 1
                continue
            }
            let key = Key(scope: .origin(origin), username: entry.username)
            // A legacy host-only item this row would supersede counts as
            // already saved, exactly as PasswordStore.save would replace it.
            let supersedes = existing.contains(Key(scope: .legacyHost(origin.host), username: entry.username))
                && CredentialScope.legacyHost(origin.host).matches(origin)
            if existing.contains(key) || supersedes, !overwriteExisting {
                skipped += 1
                continue
            }
            guard PasswordStore.save(profileName: profile.name, origin: origin, username: entry.username, password: entry.password) else {
                failed += 1
                continue
            }
            existing.insert(key)
            imported += 1
        }
        return ImportResult(importedCount: imported, skippedAsDuplicateCount: skipped, unusableCount: unusable, failedCount: failed)
    }

    /// Best-effort "secure" delete of the plaintext CSV file the user
    /// chose, offered after a successful import (Brady's own requirement).
    /// Overwrites the file's on-disk bytes with random data before
    /// unlinking it -- NOT a guarantee on modern SSDs (wear-leveling means
    /// the physical flash cells backing this logical file may already
    /// have been relocated, so an overwrite pass can miss the original
    /// data entirely), but meaningfully better than a plain remove, and
    /// it's the only thing achievable without a filesystem-specific,
    /// undocumented API. The UI's own plaintext warning is the real
    /// safeguard; this is a best-effort bonus on top of it, not a
    /// substitute for it.
    static func securelyDelete(fileAt url: URL) {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 {
            let randomData = Data((0..<size).map { _ in UInt8.random(in: .min ... .max) })
            try? randomData.write(to: url)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
