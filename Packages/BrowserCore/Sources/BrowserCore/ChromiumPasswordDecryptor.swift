import CommonCrypto
import Foundation

/// The AES key a Chromium-family browser on macOS encrypts saved passwords
/// with: PBKDF2-HMAC-SHA1 over the passphrase from its "<Name> Safe Storage"
/// keychain item, salt "saltysalt", 1003 rounds, 16 bytes
/// (`components/os_crypt/sync/os_crypt_mac.mm`).
///
/// SECURITY: never log a key, passphrase or decrypted password. The key
/// bytes are zeroed on `wipe()` and on deinit; callers should wipe as soon
/// as the last row is decrypted rather than waiting for deallocation.
public final class ChromiumSafeStorageKey {
    private var bytes: [UInt8]

    public convenience init?(passphrase: Data) {
        let key = passphrase.withUnsafeBytes { Self.derive(from: $0) }
        guard let key else { return nil }
        self.init(derivedKey: key)
    }

    /// Derives from bytes the caller owns, so a passphrase handed back by
    /// Security never needs a Swift copy of its own.
    public convenience init?(passphraseBytes: UnsafeRawBufferPointer) {
        guard let key = Self.derive(from: passphraseBytes) else { return nil }
        self.init(derivedKey: key)
    }

    private init(derivedKey: [UInt8]) {
        bytes = derivedKey
    }

    private static func derive(from passphrase: UnsafeRawBufferPointer) -> [UInt8]? {
        guard passphrase.count > 0, let base = passphrase.baseAddress else { return nil }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            base.assumingMemoryBound(to: Int8.self), passphrase.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            &key, key.count
        )
        return status == kCCSuccess ? key : nil
    }

    deinit {
        wipe()
    }

    public func wipe() {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { raw in
            _ = memset_s(raw.baseAddress, raw.count, 0, raw.count)
        }
        bytes = []
    }

    public enum Decrypted: Equatable {
        case password(String)
        /// No stored value at all (a federated or passkey-only login).
        case empty
        /// A version prefix other than `v10`, e.g. a newer scheme this
        /// importer does not know how to unwrap.
        case unsupportedFormat
        /// `v10`, but the key does not open it (wrong key, or corrupt).
        case failed
    }

    /// `v10` + AES-128-CBC, PKCS#7 padding, IV of sixteen spaces. A value
    /// with no version prefix predates encryption and is stored as-is,
    /// which is how Chromium itself reads it.
    public func decrypt(_ blob: Data) -> Decrypted {
        guard !blob.isEmpty else { return .empty }
        guard !bytes.isEmpty else { return .failed }

        let prefix = Array(blob.prefix(3))
        guard prefix == Array("v10".utf8) else {
            if prefix.count == 3, prefix[0] == UInt8(ascii: "v"),
               prefix[1...].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {
                return .unsupportedFormat
            }
            return String(data: blob, encoding: .utf8).map(Decrypted.password) ?? .unsupportedFormat
        }

        let body = Array(blob.dropFirst(3))
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return .failed }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        defer {
            out.withUnsafeMutableBytes { raw in _ = memset_s(raw.baseAddress, raw.count, 0, raw.count) }
        }
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            bytes, bytes.count, iv,
            body, body.count,
            &out, out.count, &moved
        )
        guard status == kCCSuccess else { return .failed }
        guard let text = String(bytes: out[0..<moved], encoding: .utf8) else { return .failed }
        return .password(text)
    }
}

/// Turns a profile's `Login Data` rows into importable entries.
public enum ChromiumPasswordExtractor {
    public struct Extraction {
        public let entries: [PasswordCSVEntry]
        /// Rows whose password could not be decrypted.
        public let undecryptableCount: Int
        /// Rows with no password at all.
        public let emptyCount: Int
    }

    /// "Never save" rows are dropped silently: they are a site preference,
    /// not a credential.
    public static func extract(rows: [ChromiumLoginRow], key: ChromiumSafeStorageKey) -> Extraction {
        var entries: [PasswordCSVEntry] = []
        var undecryptable = 0
        var empty = 0
        for row in rows where !row.isNeverSave {
            switch key.decrypt(row.encryptedPassword) {
            case .password(let password):
                guard !password.isEmpty else {
                    empty += 1
                    continue
                }
                entries.append(PasswordCSVEntry(url: row.originURL, username: row.username, password: password))
            case .empty:
                empty += 1
            case .unsupportedFormat, .failed:
                undecryptable += 1
            }
        }
        return Extraction(entries: entries, undecryptableCount: undecryptable, emptyCount: empty)
    }
}
