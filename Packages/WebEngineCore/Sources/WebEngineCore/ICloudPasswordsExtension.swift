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
        /// Running, and not paired with the Passwords app yet.
        case ready
        /// Running and paired: it fills from the Passwords app.
        case paired
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
        errorCount: Int,
        paired: Bool = false
    ) -> Status {
        guard extensionsAvailable else { return .needsNewerMacOS }
        guard hasEntitlement else { return .unavailableInThisBuild }
        guard installed else { return .notInstalled }
        guard enabled else { return .turnedOff }
        guard loaded && errorCount == 0 else { return .hasProblem }
        return paired ? .paired : .ready
    }

    // MARK: - Whether a profile is paired

    /// The worker says whether it is paired only through its toolbar icon:
    /// every change of its state sets `PasswordsToolbar` once the session key
    /// is set and `PasswordsToolbarUnpaired` otherwise, each in a light and a
    /// dark variant (background.js, `setGlobalState` and `setToolbarIcon`).
    /// The manifest's default icon is the paired one; it never misleads
    /// here, because the worker sets the unpaired icon before it starts its
    /// helper, so while the helper runs the icon is always one it set.
    public static let pairedIconFiles = [
        "images/PasswordsToolbar_icon32.png", "images/PasswordsToolbar-darkmode_icon32.png",
        "images/PasswordsToolbar_icon16.png", "images/PasswordsToolbar-darkmode_icon16.png",
    ]
    public static let unpairedIconFiles = [
        "images/PasswordsToolbarUnpaired_icon32.png", "images/PasswordsToolbarUnpaired-darkmode_icon32.png",
        "images/PasswordsToolbarUnpaired_icon16.png", "images/PasswordsToolbarUnpaired-darkmode_icon16.png",
    ]

    /// Paired only while the worker shows a paired icon it set itself *and*
    /// its helper runs: a session lives in the worker's memory and in the
    /// helper, so a helper that exited, or a worker that is gone, ended it
    /// whatever the icon still says. `iconFile` is the extension's file the
    /// current icon came from, nil when it matches none or is the default.
    public static func isPaired(iconFile: String?, helperRunning: Bool) -> Bool {
        guard helperRunning, let iconFile else { return false }
        return pairedIconFiles.contains(iconFile)
    }
}
