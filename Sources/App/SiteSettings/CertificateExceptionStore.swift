import Foundation

/// One profile's certificate exceptions (CertificateExceptions, WebEngineCore),
/// persisted at `<profilesRootPath>/<profile.id>/certificate-exceptions.json`.
///
/// A private window's exceptions are kept in memory only and go with the
/// app: a file under a private profile's id would be both a record of
/// private browsing and an orphan no window can show again.
final class CertificateExceptionStore {
    private let file: JSONFile<CertificateExceptions>?
    private(set) var exceptions: CertificateExceptions

    init(profileDirectory: URL?) {
        file = profileDirectory.map { JSONFile(url: $0.appendingPathComponent("certificate-exceptions.json")) }
        exceptions = file?.load(default: CertificateExceptions()) ?? CertificateExceptions()
    }

    func trusts(host: String, fingerprint: String) -> Bool {
        exceptions.trusts(host: host, fingerprint: fingerprint)
    }

    func hasException(host: String) -> Bool {
        exceptions.hasException(host: host)
    }

    func trust(host: String, fingerprint: String) {
        exceptions.trust(host: host, fingerprint: fingerprint)
        file?.save(exceptions)
    }

    func remove(host: String) {
        exceptions.remove(host: host)
        file?.save(exceptions)
    }
}

enum CertificateExceptionStoreManager {
    private static var stores: [String: CertificateExceptionStore] = [:]

    static func store(forProfileId profileId: String, isPrivate: Bool) -> CertificateExceptionStore {
        if let existing = stores[profileId] { return existing }
        let store: CertificateExceptionStore
        if isPrivate || profileId.hasPrefix(Profile.privateIdPrefix) {
            store = CertificateExceptionStore(profileDirectory: nil)
        } else {
            let directory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = CertificateExceptionStore(profileDirectory: directory)
        }
        stores[profileId] = store
        return store
    }
}
