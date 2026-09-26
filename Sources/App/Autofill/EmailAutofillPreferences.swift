import Foundation

/// App-wide autofill switches, stored through AppPreferencesStore so a
/// `--profiles-root` test launch never changes the real settings. Both
/// default to on: an unset key means "on".
enum EmailAutofillPreferences {
    private static let suggestEmailsKey = "AutofillSuggestEmailAddresses"
    private static let fillFromMeCardKey = "AutofillFillFromMyContactCard"

    /// Settings -> Autofill -> Emails -> "Suggest email addresses".
    static var suggestEmailAddresses: Bool {
        get { bool(suggestEmailsKey) }
        set { AppPreferencesStore.current.set(newValue, forKey: suggestEmailsKey) }
    }

    /// Settings -> Autofill -> Addresses -> "Fill from my contact card".
    /// Only has an effect once Contacts access is granted.
    static var fillFromMeCard: Bool {
        get { bool(fillFromMeCardKey) }
        set { AppPreferencesStore.current.set(newValue, forKey: fillFromMeCardKey) }
    }

    private static func bool(_ key: String) -> Bool {
        let defaults = AppPreferencesStore.current
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

/// Per-profile email-autofill data. A private window's profile gets a store
/// that never touches the disk, and nothing is ever created under its
/// directory (see AGENTS.md on private profile ids).
enum EmailAutofillStoreManager {
    private static let persistent = ProfileStoreCache { EmailAutofillStore(profileDirectory: $0) }
    private static var ephemeral: [String: EmailAutofillStore] = [:]

    static func store(forProfileId profileId: String) -> EmailAutofillStore {
        guard profileId.hasPrefix(Profile.privateIdPrefix) else {
            return persistent.store(forProfileId: profileId)
        }
        if let existing = ephemeral[profileId] { return existing }
        let store = EmailAutofillStore(profileDirectory: URL(fileURLWithPath: "/dev/null"), persistent: false)
        ephemeral[profileId] = store
        return store
    }

    /// Posted after Settings or a learned use changes a profile's data.
    static let didChangeNotification = Notification.Name("EmailAutofillStoreDidChange")
}
