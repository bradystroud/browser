import AppKit
import Contacts

/// Which of the contact card's values a fill uses. Built fresh from the
/// card at the moment the user chooses it, and discarded after the fill.
final class MeCardSelection {
    let card: MeCard
    var email: String?
    var phone: String?
    var address: MeCardAddress?

    init(card: MeCard, email: String?, phone: String?, address: MeCardAddress?) {
        self.card = card
        self.email = email
        self.phone = phone
        self.address = address
    }

    /// Keyed by PaymentAddressDetectionScript's field kinds, empty values
    /// left out so a fill never blanks a field the card has nothing for.
    var fieldValues: [String: String] {
        var values: [String: String] = [
            "fullName": card.fullName,
            "givenName": card.givenName,
            "familyName": card.familyName,
            "organization": card.organization,
            "jobTitle": card.jobTitle,
            "email": email ?? "",
            "tel": phone ?? "",
        ]
        if let address {
            values["streetAddress"] = address.streetAddress
            values["addressLine2"] = address.addressLine2
            values["addressLevel2"] = address.city
            values["addressLevel1"] = address.state
            values["postalCode"] = address.postalCode
            values["country"] = address.country
        }
        return values.filter { !$0.value.isEmpty }
    }

    /// One line for the menu: the name, then the chosen email or phone.
    var menuTitle: String {
        let detail = email ?? phone ?? address?.summary
        return [card.displayName, detail].compactMap { $0 }.joined(separator: " — ")
    }
}

/// The contact card ("Me") as an autofill identity: choosing its values for
/// a form, and the Contacts permission flow around it. The card is read only
/// when the user opens the fill menu, and nothing from it reaches the page
/// until they choose it.
enum MeCardAutofill {
    /// Whether the fill menu should offer the card (or the offer to use
    /// it) at all.
    static var isOffered: Bool {
        guard EmailAutofillPreferences.fillFromMeCard else { return false }
        switch ContactsAutofillSource.authorizationStatus {
        case .authorized, .notDetermined: return true
        default: return false
        }
    }

    /// The card's default values for this form: the email the smart ranker
    /// prefers for this page (see EmailSuggestionRanker) unless it has no
    /// real signal, then the one matching the form's home/work context,
    /// then the first; phones and addresses by context, then the first.
    static func defaultSelection(for card: MeCard, context: ContactContext?, tab: Tab) -> MeCardSelection {
        MeCardSelection(
            card: card,
            email: preferredEmail(card: card, context: context, tab: tab),
            phone: preferred(card.phones, context: context)?.value,
            address: preferred(card.addresses, context: context)?.value
        )
    }

    static func preferred<Value>(_ values: [MeCardValue<Value>], context: ContactContext?) -> MeCardValue<Value>? {
        if let context {
            let wanted = context == .work ? CNLabelWork : CNLabelHome
            if let match = values.first(where: { $0.rawLabel == wanted }) { return match }
        }
        return values.first
    }

    private static func preferredEmail(card: MeCard, context: ContactContext?, tab: Tab) -> String? {
        guard !card.emails.isEmpty else { return nil }
        let data = EmailAutofillStoreManager.readableData(for: tab)
        let ranked = EmailSuggestionRanker.rank(
            candidates: card.emails.map(\.value), usage: data.usage, rules: data.rules,
            pageURL: tab.urlString, limit: card.emails.count
        )
        // Only addresses from the card: a rule may name one that is not on it.
        let onCard = Set(card.emails.compactMap { EmailAddress.normalized($0.value) })
        if let top = ranked.first(where: { onCard.contains($0.email) }), top.reason != .frequency {
            return card.emails.first { EmailAddress.normalized($0.value) == top.email }?.value
        }
        return preferred(card.emails, context: context)?.value
    }

    static func openContactsPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }
}
