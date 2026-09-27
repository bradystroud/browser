import Foundation
import Security

/// Reads another Chromium browser's "<Name> Safe Storage" passphrase from
/// the login keychain and turns it straight into its AES key. The item
/// belongs to that browser, so macOS shows its own "Browser wants to use
/// your confidential information" prompt; the UI warns about that before
/// calling this.
///
/// SECURITY: read-only -- this never writes, updates or deletes any keychain
/// item, and never logs the passphrase. The key is derived straight from the
/// immutable CFData Security returns, without a Swift copy. That buffer
/// cannot be zeroed -- it is not ours to write -- so the passphrase lives
/// until Security's own object is released at the end of this call.
enum ChromiumSafeStorageKeychain {
    enum Outcome {
        case key(ChromiumSafeStorageKey)
        /// None of the browser's candidate items exists.
        case notFound
        /// The user chose Deny, or cancelled the prompt.
        case denied
        case failed(OSStatus)
    }

    static func key(for browser: ChromiumBrowser) -> Outcome {
        for item in browser.keychainItems {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &result)

            switch status {
            case errSecSuccess:
                guard let result, CFGetTypeID(result) == CFDataGetTypeID() else { return .failed(status) }
                let data = result as! CFData
                let key: ChromiumSafeStorageKey? = withExtendedLifetime(data) {
                    let length = CFDataGetLength(data)
                    guard length > 0, let pointer = CFDataGetBytePtr(data) else { return nil }
                    return ChromiumSafeStorageKey(passphraseBytes: UnsafeRawBufferPointer(start: pointer, count: length))
                }
                guard let key else { return .failed(status) }
                return .key(key)
            case errSecItemNotFound:
                continue
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                return .denied
            default:
                return .failed(status)
            }
        }
        return .notFound
    }
}
