import Foundation

extension Notification.Name {
    /// A profile's extension-controllable setting changed: an extension took
    /// or let go of it, or the user changed their own value. `object` is the
    /// profile id.
    static let extensionControlledSettingsDidChange = Notification.Name("BrowserExtensionControlledSettingsDidChange")
}

/// The profile's own "Offer to save passwords" -- the user's value of
/// `passwordSavingEnabled`, which an extension may hold instead (see
/// ExtensionControlledSettingsCenter). On unless turned off. Read through
/// `ExtensionControlledSettingsCenter.effectiveValue` by anything that acts
/// on it, never directly.
enum PasswordSavePreference {
    private static func key(_ profileId: String) -> String { "PasswordOfferToSave.\(profileId)" }

    static func userValue(profileId: String) -> Bool {
        let defaults = AppPreferencesStore.current
        guard defaults.object(forKey: key(profileId)) != nil else { return true }
        return defaults.bool(forKey: key(profileId))
    }

    static func setUserValue(_ value: Bool, profileId: String) {
        AppPreferencesStore.current.set(value, forKey: key(profileId))
        NotificationCenter.default.post(name: .extensionControlledSettingsDidChange, object: profileId)
    }
}

/// Every profile's settings held by extensions (ExtensionControlledSettings),
/// and the one place that says what value is in effect. Engine-agnostic:
/// whichever engine runs an extension reports its calls here with the
/// extension id the engine itself vouches for, never one from a message.
///
/// A private window's profile keeps its store in memory only.
final class ExtensionControlledSettingsCenter: ExtensionSettingsProvider {
    static let shared = ExtensionControlledSettingsCenter()

    private var stores: [String: ExtensionControlledSettings] = [:]

    private init() {}

    private func store(_ profileId: String) -> ExtensionControlledSettings {
        if let existing = stores[profileId] { return existing }
        let file: URL? = profileId.hasPrefix(Profile.privateIdPrefix)
            ? nil
            : URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
                .appendingPathComponent("extension-settings.json")
        let made = ExtensionControlledSettings(fileURL: file)
        stores[profileId] = made
        return made
    }

    func userValue(of setting: ExtensionControllableSetting, profileId: String) -> Bool {
        switch setting {
        case .passwordSavingEnabled: return PasswordSavePreference.userValue(profileId: profileId)
        }
    }

    func effectiveValue(of setting: ExtensionControllableSetting, profileId: String) -> Bool {
        store(profileId).effectiveValue(of: setting, userValue: userValue(of: setting, profileId: profileId))
    }

    /// The id of the extension holding `setting` in this profile, if any.
    func holder(of setting: ExtensionControllableSetting, profileId: String) -> String? {
        store(profileId).holder(of: setting)
    }

    func details(of setting: ExtensionControllableSetting, for extensionId: String, profileId: String) -> ExtensionSettingDetails {
        store(profileId).details(of: setting, for: extensionId, userValue: userValue(of: setting, profileId: profileId))
    }

    func set(_ setting: ExtensionControllableSetting, to value: Bool, by extensionId: String, profileId: String) throws {
        if try store(profileId).set(setting, to: value, by: extensionId) { changed(profileId) }
    }

    func clear(_ setting: ExtensionControllableSetting, by extensionId: String, profileId: String) {
        if store(profileId).clear(setting, by: extensionId) { changed(profileId) }
    }

    /// For an extension turned off, removed, or no longer allowed `privacy`.
    func release(extensionId: String, profileId: String) {
        if !store(profileId).release(extensionId: extensionId).isEmpty { changed(profileId) }
    }

    /// One request from an extension's `chrome.privacy` shim
    /// (ExtensionSettingsMessages), answered in its own terms. The engine
    /// carrying it vouches for `extensionId`, and has already checked that
    /// the extension was granted `privacy`.
    func handle(_ request: Any, from extensionId: String, profileId: String) -> [String: Any] {
        let outcome = ExtensionSettingsMessages.handle(request, from: extensionId, in: store(profileId)) { [unowned self] setting in
            self.userValue(of: setting, profileId: profileId)
        }
        if outcome.changed { changed(profileId) }
        return outcome.reply
    }

    /// Sends `extensionId` a change message for every controllable setting
    /// each time the profile's settings change, until the returned token is
    /// passed to `unsubscribe`.
    func subscribe(extensionId: String, profileId: String, send: @escaping ([String: Any]) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .extensionControlledSettingsDidChange, object: profileId, queue: .main) { [weak self] _ in
            guard let self else { return }
            for setting in ExtensionControllableSetting.allCases {
                send(ExtensionSettingsMessages.change(setting, for: extensionId, in: self.store(profileId),
                                                     userValue: self.userValue(of: setting, profileId: profileId)))
            }
        }
    }

    func unsubscribe(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }

    /// Forgets the cached store of a profile that was deleted.
    func forget(profileId: String) {
        stores[profileId] = nil
    }

    private func changed(_ profileId: String) {
        NotificationCenter.default.post(name: .extensionControlledSettingsDidChange, object: profileId)
    }
}
