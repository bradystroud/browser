import Foundation

/// One saved address/contact-info entry (browser-ojh.2). Not a credential
/// -- no password, no card number -- so this is plain JSON, not Keychain,
/// same reasoning as PasswordNeverStore's "never for this site" list.
public struct StoredAddress: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var fullName: String
    public var streetAddress: String
    public var addressLine2: String
    public var city: String
    /// State/province/region.
    public var state: String
    public var postalCode: String
    public var country: String
    public var phone: String
    public var email: String

    public init(
        id: String = UUID().uuidString, fullName: String = "", streetAddress: String = "",
        addressLine2: String = "", city: String = "", state: String = "", postalCode: String = "",
        country: String = "", phone: String = "", email: String = ""
    ) {
        self.id = id
        self.fullName = fullName
        self.streetAddress = streetAddress
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
        self.email = email
    }
}

/// Per-profile address-book storage, persisted as JSON at
/// `<profileDirectory>/addresses.json` -- same per-profile-directory and
/// plain-JSON-file convention as PermissionStore/PasswordNeverStore. Not
/// secret, but still deliberately kept inside the same per-user profile
/// directory as everything else profile-scoped (history, bookmarks,
/// permissions, the password never-list) rather than anywhere more broadly
/// readable -- it inherits that directory's normal user-only filesystem
/// permissions, the same protection every other per-profile JSON file in
/// this app already relies on.
public final class AddressStore {
    private let fileURL: URL
    private var addresses: [StoredAddress] = []

    public init(profileDirectory: URL) {
        fileURL = profileDirectory.appendingPathComponent("addresses.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StoredAddress].self, from: data)
        else {
            addresses = []
            return
        }
        addresses = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(addresses) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func all() -> [StoredAddress] {
        addresses
    }

    /// Adds a new address, or overwrites an existing one with the same id.
    public func save(_ address: StoredAddress) {
        if let index = addresses.firstIndex(where: { $0.id == address.id }) {
            addresses[index] = address
        } else {
            addresses.append(address)
        }
        save()
    }

    public func delete(id: String) {
        addresses.removeAll { $0.id == id }
        save()
    }
}
