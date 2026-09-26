import Foundation

/// Everything email autofill keeps for one profile.
public struct EmailAutofillData: Codable, Equatable, Sendable {
    /// Addresses the user added by hand in Settings.
    public var addresses: [String] = []
    /// Where addresses have been used, learned from submitted forms.
    public var usage: [EmailUsageRecord] = []
    public var rules: [EmailRule] = []

    public init(addresses: [String] = [], usage: [EmailUsageRecord] = [], rules: [EmailRule] = []) {
        self.addresses = addresses
        self.usage = usage
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
        usage = try container.decodeIfPresent([EmailUsageRecord].self, forKey: .usage) ?? []
        rules = try container.decodeIfPresent([EmailRule].self, forKey: .rules) ?? []
    }
}

/// Per-profile email-autofill storage at `<profileDirectory>/email-autofill.json`.
///
/// A store made with `persistent: false` never touches the disk -- that is
/// the only kind a private window may use (see AGENTS.md on private
/// profile ids).
public final class EmailAutofillStore {
    /// Oldest-first pruning keeps the file small; nobody needs the 501st site
    /// they ever typed an email into to shape suggestions.
    public static let maximumUsageRecords = 500

    private let file: JSONFile<EmailAutofillData>?
    public private(set) var data: EmailAutofillData

    public init(profileDirectory: URL, persistent: Bool = true) {
        if persistent {
            let file = JSONFile<EmailAutofillData>(url: profileDirectory.appendingPathComponent("email-autofill.json"))
            self.file = file
            data = file.load(default: EmailAutofillData())
        } else {
            file = nil
            data = EmailAutofillData()
        }
    }

    private func save() {
        file?.save(data)
    }

    // MARK: - Your addresses

    @discardableResult
    public func addAddress(_ raw: String) -> Bool {
        guard let email = EmailAddress.normalized(raw), !data.addresses.contains(email) else { return false }
        data.addresses.append(email)
        save()
        return true
    }

    public func removeAddress(_ email: String) {
        data.addresses.removeAll { $0 == email }
        save()
    }

    // MARK: - Learned usage

    /// Records that `rawEmail` was committed in a form on `pageURL` -- the
    /// engine's verified URL for the tab. Returns false when there was
    /// nothing to record (not an email, or no host).
    @discardableResult
    public func recordUse(email rawEmail: String, pageURL: String, at date: Date = Date()) -> Bool {
        guard let email = EmailAddress.normalized(rawEmail),
              let host = URLComponents(string: pageURL)?.host?.lowercased(), !host.isEmpty
        else { return false }
        let tenantKey = IdentityProviderHints.parse(urlString: pageURL).tenantKey
        if let index = data.usage.firstIndex(where: { $0.email == email && $0.host == host && $0.tenantKey == tenantKey }) {
            data.usage[index].count += 1
            data.usage[index].lastUsed = max(data.usage[index].lastUsed, date)
        } else {
            data.usage.append(EmailUsageRecord(
                email: email, siteDomain: RegistrableDomain.of(host: host), host: host,
                tenantKey: tenantKey, lastUsed: date, count: 1
            ))
        }
        if data.usage.count > Self.maximumUsageRecords {
            data.usage.sort { $0.lastUsed > $1.lastUsed }
            data.usage.removeLast(data.usage.count - Self.maximumUsageRecords)
        }
        save()
        return true
    }

    public func removeUsage(id: String) {
        data.usage.removeAll { $0.id == id }
        save()
    }

    public func clearUsage() {
        data.usage.removeAll()
        save()
    }

    // MARK: - Rules

    public func saveRule(_ rule: EmailRule) {
        if let index = data.rules.firstIndex(where: { $0.id == rule.id }) {
            data.rules[index] = rule
        } else {
            data.rules.append(rule)
        }
        save()
    }

    public func removeRule(id: String) {
        data.rules.removeAll { $0.id == id }
        save()
    }
}
