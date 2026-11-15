import Foundation

/// The browser's side of the settings an extension may hold (Chrome's
/// `chrome.privacy` ChromeSettings this browser really has). The app's
/// engine-agnostic ExtensionControlledSettingsCenter implements it; each
/// engine only carries an extension's requests here, naming the extension
/// as the engine itself knows it, and says when an extension stops running
/// for good. Messages are ExtensionSettingsMessages' dictionaries: setting
/// names, values and levels of control, nothing else.
protocol ExtensionSettingsProvider: AnyObject {
    func handle(_ request: Any, from extensionId: String, profileId: String) -> [String: Any]
    func subscribe(extensionId: String, profileId: String, send: @escaping ([String: Any]) -> Void) -> NSObjectProtocol
    func unsubscribe(_ token: NSObjectProtocol)
    /// The extension was turned off or removed: whatever it held returns to
    /// the user's own value.
    func release(extensionId: String, profileId: String)
    /// The profile was deleted.
    func forget(profileId: String)
}

/// Where an engine finds the provider. Set once by the app at startup; nil
/// leaves the settings host unanswered, and the shim then reports the
/// settings as `not_controllable`.
enum ExtensionSettingsHost {
    static var provider: ExtensionSettingsProvider?
}
