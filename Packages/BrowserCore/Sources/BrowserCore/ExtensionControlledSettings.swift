import Foundation

/// A browser setting an extension may take control of, named as Chrome's
/// `chrome.privacy` API names it. Only settings this browser really has, and
/// that an extension has a reason to hold, are listed: anything else stays
/// `not_controllable` in the extension's view.
public enum ExtensionControllableSetting: String, Codable, CaseIterable {
    /// Whether the browser offers to save passwords. Its own value is the
    /// profile's "Offer to save passwords"; a password-manager extension
    /// holds it at false so that a sign-in gets one save prompt, its own.
    case passwordSavingEnabled = "services.passwordSavingEnabled"
}

/// Chrome's `ChromeSetting.levelOfControl`, as the extension asking sees it.
public enum ExtensionSettingLevelOfControl: String, Codable, Equatable {
    case notControllable = "not_controllable"
    case controlledByOtherExtensions = "controlled_by_other_extensions"
    case controllableByThisExtension = "controllable_by_this_extension"
    case controlledByThisExtension = "controlled_by_this_extension"
}

/// What `ChromeSetting.get` answers: the value in effect, and who decides it.
public struct ExtensionSettingDetails: Equatable {
    public let value: Bool
    public let levelOfControl: ExtensionSettingLevelOfControl

    public init(value: Bool, levelOfControl: ExtensionSettingLevelOfControl) {
        self.value = value
        self.levelOfControl = levelOfControl
    }
}

public enum ExtensionSettingError: Error, Equatable, CustomStringConvertible {
    /// Another extension holds the setting; Chrome refuses the same way.
    case controlledByOtherExtension

    public var description: String {
        switch self {
        case .controlledByOtherExtension: return "Another extension controls this setting."
        }
    }
}

/// One profile's settings held by extensions: for each setting, which
/// extension holds it and at what value. The user's own value is never
/// stored here -- it stays wherever the app keeps it, and comes back by
/// itself the moment the extension lets go.
///
/// A setting has at most one holder. The first extension to set it keeps it
/// until it clears it, is turned off or removed (`release`); another
/// extension sees `controlled_by_other_extensions` and its `set` is
/// refused. (Chrome gives a contested setting to the most recently
/// installed extension instead; with one holder there is nothing to rank.)
///
/// The extension id is whatever the engine says the caller is, never
/// something a message claims. Not thread-safe: one owner, on one queue.
public final class ExtensionControlledSettings {
    public struct Control: Codable, Equatable {
        public let extensionId: String
        public let value: Bool

        public init(extensionId: String, value: Bool) {
            self.extensionId = extensionId
            self.value = value
        }
    }

    private let file: JSONFile<[String: Control]>?
    /// Keyed by the setting's raw name, so a file written by a later version
    /// that knows more settings keeps them through a save by this one.
    private var controls: [String: Control]

    /// `fileURL` nil keeps everything in memory, for a profile that must
    /// leave nothing on disk (a private window's).
    public init(fileURL: URL?) {
        file = fileURL.map { JSONFile(url: $0) }
        controls = file?.load(default: [:]) ?? [:]
    }

    public func holder(of setting: ExtensionControllableSetting) -> String? {
        controls[setting.rawValue]?.extensionId
    }

    /// The value in effect: the holder's, or else the user's own.
    public func effectiveValue(of setting: ExtensionControllableSetting, userValue: Bool) -> Bool {
        controls[setting.rawValue]?.value ?? userValue
    }

    public func details(of setting: ExtensionControllableSetting, for extensionId: String, userValue: Bool) -> ExtensionSettingDetails {
        guard let control = controls[setting.rawValue] else {
            return ExtensionSettingDetails(value: userValue, levelOfControl: .controllableByThisExtension)
        }
        let level: ExtensionSettingLevelOfControl = control.extensionId == extensionId
            ? .controlledByThisExtension : .controlledByOtherExtensions
        return ExtensionSettingDetails(value: control.value, levelOfControl: level)
    }

    /// Takes or keeps control at `value`. Returns whether anything changed.
    @discardableResult
    public func set(_ setting: ExtensionControllableSetting, to value: Bool, by extensionId: String) throws -> Bool {
        let wanted = Control(extensionId: extensionId, value: value)
        if let current = controls[setting.rawValue] {
            guard current.extensionId == extensionId else { throw ExtensionSettingError.controlledByOtherExtension }
            if current == wanted { return false }
        }
        controls[setting.rawValue] = wanted
        save()
        return true
    }

    /// Lets go of `setting` if `extensionId` holds it; clearing a setting
    /// held by someone else, or by nobody, changes nothing, as in Chrome.
    @discardableResult
    public func clear(_ setting: ExtensionControllableSetting, by extensionId: String) -> Bool {
        guard controls[setting.rawValue]?.extensionId == extensionId else { return false }
        controls[setting.rawValue] = nil
        save()
        return true
    }

    /// Everything `extensionId` holds, let go -- for an extension turned
    /// off, removed, or no longer granted the permission. Returns what was
    /// released.
    @discardableResult
    public func release(extensionId: String) -> [ExtensionControllableSetting] {
        let held = ExtensionControllableSetting.allCases.filter { controls[$0.rawValue]?.extensionId == extensionId }
        let unknown = controls.filter { ExtensionControllableSetting(rawValue: $0.key) == nil && $0.value.extensionId == extensionId }
        guard !held.isEmpty || !unknown.isEmpty else { return [] }
        for setting in held { controls[setting.rawValue] = nil }
        for key in unknown.keys { controls[key] = nil }
        save()
        return held
    }

    private func save() {
        file?.save(controls)
    }
}
