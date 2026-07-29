import Foundation

/// Writes parsed CSV password entries into PasswordStore (browser-ymx),
/// deduped by (origin host, username) -- an existing saved credential wins
/// unless the caller opts to overwrite. Pure Keychain/PasswordStore glue,
/// no UI; SafariImportWindowController's Passwords section is the only
/// caller.
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
    }

    /// `overwriteExisting`: when false (the default UI choice), an entry
    /// whose (host, username) already has a saved credential in `profile`
    /// is skipped rather than replacing it -- "existing entry wins," per
    /// Brady's own spec.
    static func importEntries(_ entries: [PasswordCSVEntry], into profile: Profile, overwriteExisting: Bool) -> ImportResult {
        struct Key: Hashable {
            let host: String
            let username: String
        }

        // One allCredentials() read up front rather than one Keychain
        // query per row -- this set is kept up to date as rows are
        // imported below, so a CSV with duplicate rows for the same
        // (host, username) still dedupes correctly against itself, not
        // just against what was already saved before this import started.
        var existing = Set(PasswordStore.allCredentials(profileName: profile.name).map { Key(host: $0.origin, username: $0.username) })

        var imported = 0
        var skipped = 0
        for entry in entries {
            let host = hostOnly(entry.url)
            guard !host.isEmpty, !entry.username.isEmpty else {
                skipped += 1
                continue
            }
            let key = Key(host: host, username: entry.username)
            if existing.contains(key), !overwriteExisting {
                skipped += 1
                continue
            }
            guard PasswordStore.save(profileName: profile.name, origin: host, username: entry.username, password: entry.password) else {
                skipped += 1
                continue
            }
            existing.insert(key)
            imported += 1
        }
        return ImportResult(importedCount: imported, skippedAsDuplicateCount: skipped)
    }

    /// Mirrors PasswordStore's own private `host(fromOrigin:)` -- a CSV
    /// row's `url` column is a full URL ("https://example.com/login"),
    /// but PasswordStore keys strictly on host, matching every other
    /// caller's contract.
    private static func hostOnly(_ url: String) -> String {
        if let parsed = URL(string: url), let host = parsed.host {
            return host
        }
        return url
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
