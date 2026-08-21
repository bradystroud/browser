import Foundation

/// Host and origin derivation for the per-site settings sheet (browser-06d).
///
/// One place, because the stores that sheet writes are keyed two different
/// ways: BlockingSettings.allowlistedHosts and CEF's own HostZoomMap by
/// *host*, PermissionStore by *origin*. A sheet that derived either of them
/// slightly differently from the store that owns it would write settings the
/// store never reads back -- silently, with the UI still showing the value
/// the user chose.
enum SiteIdentity {
    /// The lowercased host of an http(s) URL, or nil for anything else -- a
    /// start page, a data: URL, about:blank. Every per-site setting here is
    /// keyed by host or by an origin built from one, so nil means "there is
    /// nothing on this page to configure".
    static func host(forURLString urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return host.lowercased()
    }

    /// The origin of an http(s) URL: scheme, host, and a port only when it
    /// is not the scheme's default -- "https://example.com". PermissionStore
    /// keys by origin, and it folds the trailing slash Chromium's own GURL
    /// spec carries ("https://example.com/") into this same shape, so a write
    /// from the sheet and a write from the permission prompt land on one key
    /// rather than two spellings of the same site.
    static func origin(forURLString urlString: String) -> String? {
        guard let host = host(forURLString: urlString),
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased()
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

/// Everything the per-site sheet persists that no existing store already
/// owns. Today that is exactly one flag, and the bar for adding a second is
/// the same as the bar for the first: the app must be able to genuinely
/// enforce it (see SiteSettingsEnforcer), not merely remember it.
struct SiteSettingsRecord: Codable, Equatable {
    /// Mute this site's audio as soon as a tab lands on it. This is a real
    /// CefBrowserHost::SetAudioMuted call per tab, not an autoplay policy:
    /// video on the site still plays, it just plays silently. Chromium's
    /// actual per-site autoplay setting is a Chrome-style-only surface this
    /// Alloy app cannot reach, which is why the sheet offers this and does
    /// not claim to stop auto-play.
    var autoMute: Bool

    init(autoMute: Bool = false) {
        self.autoMute = autoMute
    }

    /// Decoding tolerates a missing key rather than failing the whole file,
    /// so a record written by a build with a different set of flags still
    /// loads here with the absent ones at their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoMute = try container.decodeIfPresent(Bool.self, forKey: .autoMute) ?? false
    }

    /// True when nothing is set. Such a record is dropped rather than
    /// written, so the file only ever lists hosts the user actually changed.
    var isDefault: Bool { self == SiteSettingsRecord() }
}

/// Per-profile, per-host site settings, persisted as JSON at
/// `<profilesRootPath>/<profile.id>/site-settings.json` -- the same
/// per-profile directory, keyed by the profile's immutable id, that
/// PermissionStore's permissions.json and BlockingSettingsStore's
/// blocking.json already use (browser-ojw).
///
/// Keyed by *host*, not origin: the settings here are the ones the user
/// thinks of as belonging to "this website" rather than to a security
/// origin, and both of the neighbouring host-keyed stores (the content
/// blocker allowlist, CEF's zoom map) already draw the line in that place.
final class SiteSettingsStore {
    private let fileURL: URL
    private var records: [String: SiteSettingsRecord] = [:]

    init(profileDirectory: URL) {
        fileURL = profileDirectory.appendingPathComponent("site-settings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SiteSettingsRecord].self, from: data)
        else {
            records = [:]
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// This host's settings, or an all-defaults record for a host that has
    /// never been configured.
    func record(for host: String) -> SiteSettingsRecord {
        records[host.lowercased()] ?? SiteSettingsRecord()
    }

    func setRecord(_ record: SiteSettingsRecord, for host: String) {
        let key = host.lowercased()
        if record.isDefault {
            records.removeValue(forKey: key)
        } else {
            records[key] = record
        }
        save()
    }

    func setAutoMute(_ autoMute: Bool, for host: String) {
        var record = record(for: host)
        record.autoMute = autoMute
        setRecord(record, for: host)
    }

    /// Forgets everything for one host -- the sheet's "Restore Defaults".
    func clear(host: String) {
        setRecord(SiteSettingsRecord(), for: host)
    }
}

/// Lazily opens and caches one `SiteSettingsStore` per profile, keyed by
/// `Profile.id`, mirroring PermissionStoreManager's pattern.
final class SiteSettingsStoreManager {
    static let shared = SiteSettingsStoreManager()

    private var cache: [String: SiteSettingsStore] = [:]

    private init() {}

    func store(for profile: Profile) -> SiteSettingsStore {
        if let existing = cache[profile.id] {
            return existing
        }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profile.id))
        try? FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let store = SiteSettingsStore(profileDirectory: profileDirectory)
        cache[profile.id] = store
        return store
    }
}
