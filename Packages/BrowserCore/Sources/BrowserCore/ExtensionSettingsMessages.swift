import Foundation

/// The messages an extension's `chrome.privacy` shim exchanges with the
/// browser about a setting it may hold (see ChromeExtensionCompatibility's
/// settingsTransport), whichever engine carries them:
///
///   request  { "setting": "services.passwordSavingEnabled", "op": "get" | "set" | "clear", "value": Bool }
///   answer   { "value": Bool, "levelOfControl": String }  or  { "error": String }
///   change   { "setting": String, "value": Bool, "levelOfControl": String }
///
/// Only setting names, values and levels of control ever cross: nothing the
/// browser stores beyond that is reachable this way. Who is asking is never
/// read from a message -- the engine says which extension the request came
/// from, and that is the id passed in here.
public enum ExtensionSettingsMessages {
    public struct Outcome {
        public let reply: [String: Any]
        /// The setting's holder or value changed, so every listener in the
        /// profile is told (`change`).
        public let changed: Bool
    }

    public static func handle(_ request: Any, from extensionId: String, in store: ExtensionControlledSettings,
                              userValue: (ExtensionControllableSetting) -> Bool) -> Outcome {
        guard let fields = request as? [String: Any],
              let name = fields["setting"] as? String,
              let op = fields["op"] as? String
        else { return failure("The request is not one this browser understands.") }
        guard let setting = ExtensionControllableSetting(rawValue: name) else {
            return failure("This browser does not let extensions change \(name).")
        }
        var changed = false
        switch op {
        case "get":
            break
        case "set":
            // JSON true/false arrive as NSNumber; only a real boolean counts.
            guard let number = fields["value"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return failure("The value must be true or false.")
            }
            do {
                changed = try store.set(setting, to: number.boolValue, by: extensionId)
            } catch let error as ExtensionSettingError {
                return failure(error.description)
            } catch {
                return failure("The setting could not be changed.")
            }
        case "clear":
            changed = store.clear(setting, by: extensionId)
        default:
            return failure("The request is not one this browser understands.")
        }
        let details = store.details(of: setting, for: extensionId, userValue: userValue(setting))
        return Outcome(reply: answer(details), changed: changed)
    }

    /// What one listening extension is told after `setting` changed: the
    /// value in effect and its own level of control, which differs from one
    /// extension to the next.
    public static func change(_ setting: ExtensionControllableSetting, for extensionId: String,
                              in store: ExtensionControlledSettings, userValue: Bool) -> [String: Any] {
        var message = answer(store.details(of: setting, for: extensionId, userValue: userValue))
        message["setting"] = setting.rawValue
        return message
    }

    private static func answer(_ details: ExtensionSettingDetails) -> [String: Any] {
        ["value": details.value, "levelOfControl": details.levelOfControl.rawValue]
    }

    private static func failure(_ text: String) -> Outcome {
        Outcome(reply: ["error": text], changed: false)
    }
}
