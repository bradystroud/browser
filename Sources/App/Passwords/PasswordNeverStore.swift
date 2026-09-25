import Foundation

/// Per-profile "never save a password for this site" decisions, persisted
/// as JSON at `<profilesRootPath>/<profileId>/password-never-list.json`
/// (browser-ojw) -- same per-profile-directory and plain-JSON-file
/// conventions as PermissionStore (browser-12m.2), and for the same reason:
/// this is a small set of opt-outs, not a credential, so there's nothing
/// here that needs Keychain-level protection the way PasswordStore's
/// actual saved passwords do.
final class PasswordNeverStore {
    private let file: JSONFile<Set<String>>
    private var neverOrigins: Set<String>

    init(profileDirectory: URL) {
        file = JSONFile(url: profileDirectory.appendingPathComponent("password-never-list.json"))
        neverOrigins = file.load(default: [])
    }

    private func save() {
        file.save(neverOrigins)
    }

    /// `origin` is matched exactly as passed by the save-prompt flow (the
    /// page's `location.origin`, e.g. "https://example.com") -- unlike
    /// PasswordStore's Keychain items, which key on host only, this
    /// deliberately keys on the full origin: "never save on this origin"
    /// is a narrower, more conservative opt-out than "never save on this
    /// host at any scheme/port," and getting that wrong in the permissive
    /// direction (over-suppressing future prompts) is the worse failure
    /// mode for a security-relevant preference.
    func isNeverForSite(_ origin: String) -> Bool {
        neverOrigins.contains(origin)
    }

    func setNeverForSite(_ origin: String) {
        neverOrigins.insert(origin)
        save()
    }

    /// Un-does a previous "Never" -- exposed for the Settings pane, so a
    /// user who opted out by mistake has a way back without needing to
    /// delete/reinstall a profile.
    func clearNeverForSite(_ origin: String) {
        neverOrigins.remove(origin)
        save()
    }
}

enum PasswordNeverStoreManager {
    static let shared = ProfileStoreCache(PasswordNeverStore.init(profileDirectory:))
}
