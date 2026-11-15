import Foundation

/// Apple's "iCloud Passwords" Chrome extension, which talks to a helper that
/// is part of macOS and fills from the Passwords app.
public enum ICloudPasswordsExtension {
    public static let storeID = "pejdijmoenmkgeppbflobdenhhabjlaj"
    public static let storeLink = "https://chromewebstore.google.com/detail/icloud-passwords/\(storeID)"

    /// What Settings shows for the extension. Cases are ordered from "cannot
    /// act" to "working".
    public enum Status: Equatable {
        /// No engine in this run supports extensions.
        case needsNewerMacOS
        /// macOS starts the helper only for a build signed with Apple's
        /// browser passkey entitlement.
        case unavailableInThisBuild
        case notInstalled
        case ready
        case turnedOff
        /// Installed and enabled, but not loaded or reporting errors.
        case hasProblem
    }

    public static func status(
        extensionsAvailable: Bool,
        hasEntitlement: Bool,
        installed: Bool,
        enabled: Bool,
        loaded: Bool,
        errorCount: Int
    ) -> Status {
        guard extensionsAvailable else { return .needsNewerMacOS }
        guard hasEntitlement else { return .unavailableInThisBuild }
        guard installed else { return .notInstalled }
        guard enabled else { return .turnedOff }
        return loaded && errorCount == 0 ? .ready : .hasProblem
    }
}
