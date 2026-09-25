import Foundation

/// App-side glue for AddressStore: it lives in the AutofillCore package,
/// keyed by a plain directory URL, since the package can't depend on this
/// app's CommandLineArgs to resolve a profile's directory itself.
enum AddressStoreManager {
    static let shared = ProfileStoreCache(AddressStore.init(profileDirectory:))
}
