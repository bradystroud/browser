import Contacts

/// One contact's info, shaped for filling into a recognized address form --
/// not a StoredAddress (this is never saved anywhere; it's read fresh from
/// Contacts.app each time and only ever flows into AutofillFillScript.
/// fillAddressScript, exactly like a saved address does).
struct ContactFillCandidate {
    let id: String
    let displayName: String
    let fullName: String
    let streetAddress: String
    let addressLine2: String
    let city: String
    let state: String
    let postalCode: String
    let country: String
    let phone: String
    let email: String
}

/// Wraps CNContactStore for "Fill from Contacts…" (browser-ojh.3) -- the
/// user's own macOS Contacts, offered alongside saved addresses in the
/// same fill-icon menu (PaymentAddressAutofillCoordinator). Every access
/// goes through requestAccessIfNeeded first; nothing here ever calls
/// CNContactStore directly without having confirmed authorization,
/// including the very first read of authorizationStatus, which is safe to
/// call before any prompt has ever shown (it just reports .notDetermined).
enum ContactsAutofillSource {
    /// The exact fields fetched -- name, postal addresses, phones, emails.
    /// Nothing else is ever read from a contact (no photo, no notes, no
    /// birthday, etc.) -- only what a recognized address/identity form
    /// could actually use.
    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    /// Calls `completion(true)` if Contacts access is already (or is now)
    /// granted, `completion(false)` otherwise -- including the "denied/
    /// restricted" case, where this deliberately does NOT call
    /// requestAccess again: macOS itself won't show the system prompt a
    /// second time after a user has denied it once, so calling it again
    /// would just silently re-invoke the completion with the same denial,
    /// giving no way back except System Settings. Always calls `completion`
    /// on the main thread exactly once.
    static func requestAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            completion(true)
        case .notDetermined:
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    /// Fetches every contact with at least a name, a postal address, a
    /// phone, or an email -- callers should only call this after
    /// requestAccessIfNeeded's completion reports `true`. Returns an empty
    /// array (rather than crashing/throwing further) on any Contacts-
    /// framework error, since a fill-source menu silently offering nothing
    /// is a much better failure mode than crashing the whole app over a
    /// transient Contacts.app database issue.
    static func fetchCandidates() -> [ContactFillCandidate] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var results: [ContactFillCandidate] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let address = contact.postalAddresses.first?.value
            let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
            let email = contact.emailAddresses.first.map { String($0.value) } ?? ""

            guard !fullName.isEmpty || address != nil || !phone.isEmpty || !email.isEmpty else { return }

            let streetLines = (address?.street ?? "").components(separatedBy: "\n")
            results.append(ContactFillCandidate(
                id: contact.identifier,
                displayName: fullName.isEmpty ? (email.isEmpty ? phone : email) : fullName,
                fullName: fullName,
                streetAddress: streetLines.first ?? "",
                addressLine2: streetLines.count > 1 ? streetLines.dropFirst().joined(separator: ", ") : "",
                city: address?.city ?? "",
                state: address?.state ?? "",
                postalCode: address?.postalCode ?? "",
                country: address?.country ?? "",
                phone: phone,
                email: email
            ))
        }
        return results.sorted { $0.displayName < $1.displayName }
    }
}
