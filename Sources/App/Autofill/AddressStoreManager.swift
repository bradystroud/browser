import Foundation

/// Lazily opens and caches one AddressStore per profile id (browser-ojw) --
/// mirrors PasswordNeverStoreManager's pattern (AddressStore itself lives in
/// the AutofillCore package, keyed by a plain directory URL, since the
/// package can't depend on this app's CommandLineArgs; this manager is the
/// app-side glue that resolves that directory and caches the result).
final class AddressStoreManager {
    static let shared = AddressStoreManager()

    private var cache: [String: AddressStore] = [:]

    private init() {}

    func store(forProfileId profileId: String) -> AddressStore {
        if let existing = cache[profileId] {
            return existing
        }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
        try? FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let store = AddressStore(profileDirectory: profileDirectory)
        cache[profileId] = store
        return store
    }
}
