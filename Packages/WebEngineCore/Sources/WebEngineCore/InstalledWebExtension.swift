import Foundation

/// One extension installed in one profile, as written to that profile's
/// `Extensions/installed.json`.
public struct InstalledWebExtension: Codable, Equatable {
    public enum Source: String, Codable {
        /// Downloaded from the Chrome Web Store and unpacked into the
        /// profile's own extensions folder under its id.
        case webStore
        /// Loaded in place from a developer's folder (`unpackedPath`), and
        /// read afresh from there on Reload.
        case unpacked
    }

    public let id: String
    public var source: Source
    public var name: String
    public var version: String
    public var enabled: Bool
    public var pinned: Bool
    public var unpackedPath: String?
    /// Everything the user has agreed to: the permissions and host patterns
    /// shown at install (see `WebExtensionGrants`), plus any optional ones
    /// granted since. Re-applied on every load, and compared against on
    /// every update and reload.
    public var grants: [String]
    public var installedAt: Date
    public var lastUpdateCheck: Date?

    public init(id: String, source: Source, name: String, version: String, enabled: Bool = true, pinned: Bool = false,
                unpackedPath: String? = nil, grants: [String], installedAt: Date = Date(), lastUpdateCheck: Date? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.version = version
        self.enabled = enabled
        self.pinned = pinned
        self.unpackedPath = unpackedPath
        self.grants = grants
        self.installedAt = installedAt
        self.lastUpdateCheck = lastUpdateCheck
    }
}

/// The list file itself. Order is install order, which is also the order
/// the extensions menu shows.
public struct InstalledWebExtensionList: Codable, Equatable {
    public var extensions: [InstalledWebExtension]
    public var lastUpdateCheck: Date?

    public init(extensions: [InstalledWebExtension] = [], lastUpdateCheck: Date? = nil) {
        self.extensions = extensions
        self.lastUpdateCheck = lastUpdateCheck
    }

    public static func load(from url: URL) -> InstalledWebExtensionList {
        guard let data = try? Data(contentsOf: url) else { return InstalledWebExtensionList() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(InstalledWebExtensionList.self, from: data)) ?? InstalledWebExtensionList()
    }

    /// The folder must already exist; saving never creates it.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Whether the daily store check is due.
    public func isUpdateCheckDue(now: Date = Date(), interval: TimeInterval = 20 * 60 * 60) -> Bool {
        guard let last = lastUpdateCheck else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }
}

/// What an extension may do, flattened to strings so an install's consent
/// can be stored and a later version's request compared with it:
/// `perm:<name>` for an API permission, `host:<match pattern>` for site
/// access.
public enum WebExtensionGrants {
    public static func make(permissions: some Sequence<String>, matchPatterns: some Sequence<String>) -> [String] {
        Set(permissions.map { "perm:" + $0 }).union(matchPatterns.map { "host:" + $0 }).sorted()
    }

    /// What `requested` asks for beyond what was agreed to. Non-empty means
    /// the update or reload must be put to the user again.
    public static func added(_ requested: [String], beyond granted: [String]) -> [String] {
        let agreed = Set(granted)
        // Access to every site already covers any single one.
        let hasAllHosts = agreed.contains { isAllHosts($0) }
        return Set(requested).subtracting(agreed).filter { !(hasAllHosts && $0.hasPrefix("host:")) }.sorted()
    }

    public static func permissions(in grants: [String]) -> [String] {
        grants.compactMap { $0.hasPrefix("perm:") ? String($0.dropFirst(5)) : nil }
    }

    public static func matchPatterns(in grants: [String]) -> [String] {
        grants.compactMap { $0.hasPrefix("host:") ? String($0.dropFirst(5)) : nil }
    }

    static func isAllHosts(_ grant: String) -> Bool {
        grant == "host:<all_urls>" || grant == "host:*://*/*"
    }
}
