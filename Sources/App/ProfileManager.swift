import Foundation

/// Profiles persisted as JSON under
/// ~/Library/Application Support/Browser/profiles.json. This is the single
/// source of truth for what profiles exist and their display identity (name,
/// color); it is independent of BRWEngine's profile-name -> CefRequestContext
/// map, which just needs a profile's `name` to key its cache directory.
final class ProfileManager {
    static let shared = ProfileManager()

    static let defaultProfileName = "default"

    private let fileURL: URL
    private(set) var profiles: [Profile] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Browser")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")
        load()
        if profiles.isEmpty {
            _ = createProfile(name: Self.defaultProfileName, colorHex: ProfileColorPalette.hexValues[7])
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func profile(named name: String) -> Profile? {
        profiles.first { $0.name == name }
    }

    /// Looks up a profile by name, auto-creating it if missing -- this is
    /// what keeps the `--profile <name>` launch argument working for any
    /// name, per AGENTS.md.
    @discardableResult
    func profileOrCreate(named name: String) -> Profile {
        if let existing = profile(named: name) {
            return existing
        }
        return createProfile(name: name, colorHex: nextUnusedColor())
    }

    @discardableResult
    func createProfile(name: String, colorHex: String) -> Profile {
        let profile = Profile(id: UUID().uuidString, name: name, colorHex: colorHex)
        profiles.append(profile)
        save()
        return profile
    }

    func nextUnusedColor() -> String {
        let used = Set(profiles.map { $0.colorHex })
        return ProfileColorPalette.hexValues.first { !used.contains($0) }
            ?? ProfileColorPalette.hexValues[profiles.count % ProfileColorPalette.hexValues.count]
    }
}
