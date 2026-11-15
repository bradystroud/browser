import Foundation

/// Receives the developer key a store package's signature check proved. The
/// check runs off the main thread; the key is read after it returns.
final class CRXPublicKeySink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var key: Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// The form `InstalledWebExtension.publicKey` keeps.
    var base64: String? { key?.base64EncodedString() }

    func keep(_ key: Data) {
        lock.lock()
        stored = key
        lock.unlock()
    }

    /// `Crx3.verifiedArchive`, also handing `sink` the key when there is one.
    static func verifiedArchive(_ crx: Data, expectedID: String, keepingKeyIn sink: CRXPublicKeySink?) throws -> Data {
        guard let sink else { return try Crx3.verifiedArchive(crx, expectedID: expectedID) }
        let package = try Crx3.verifiedPackage(crx, expectedID: expectedID)
        sink.keep(package.publicKey)
        return package.archive
    }
}

/// The owner of a profile's install list, for what another runtime learns
/// about an installed extension and has to keep on its record.
protocol EngineExtensionInstallList: AnyObject {
    /// Stores the developer key of an installed store extension. False when
    /// the extension is not installed there, or the key is not its.
    @MainActor func storePublicKey(_ key: Data, extensionId: String, profileId: String) -> Bool
}

@available(macOS 15.4, *)
extension WebKitExtensionManager: EngineExtensionInstallList {
    @MainActor
    func storePublicKey(_ key: Data, extensionId id: String, profileId: String) -> Bool {
        guard ChromeExtensionID.from(publicKey: key) == id,
              let profile = profile(for: profileId), profile.record(id)?.source == .webStore else { return false }
        profile.update(id) { $0.publicKey = key.base64EncodedString() }
        profile.save()
        return true
    }
}
