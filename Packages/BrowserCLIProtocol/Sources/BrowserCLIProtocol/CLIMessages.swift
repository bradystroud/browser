import Foundation

/// One CLI request, sent as a single newline-terminated JSON object over the
/// socket at `CLISocketPath.path(inDirectory:)` -- one request per
/// connection (connect, write, read one response line, close), no
/// persistent session. `args` is deliberately a flat string dictionary
/// rather than a per-command payload type: this is a small, slow-moving
/// protocol (a handful of CLI commands, not a general RPC framework), so one
/// flexible shape that every command parses its own way is simpler than a
/// generic envelope + per-command Codable payload type pair.
public struct CLIRequest: Codable {
    public let command: String
    public let args: [String: String]

    public init(command: String, args: [String: String] = [:]) {
        self.command = command
        self.args = args
    }
}

/// The response to any `CLIRequest`, same one-line-JSON framing. `ok`/
/// `error` are always meaningful; the rest are populated only by the
/// command that actually produced them (nil otherwise) -- see each field's
/// own doc comment for which command fills it in. Deliberately never has a
/// field for password/credential data, and never should -- the CLI has no
/// business surfacing that even behind `--json` (browser-82d's explicit
/// guard).
public struct CLIResponse: Codable {
    public var ok: Bool
    public var error: String?

    /// A short human-readable summary for the non-`--json` text output --
    /// e.g. "Opened https://example.com in profile 'work' (matched rule
    /// #2)." Every successful command sets this; `--json` output ignores it
    /// in favor of the structured fields below.
    public var message: String?

    /// Populated by `profiles`.
    public var profiles: [CLIProfileInfo]?
    /// Populated by `tabs`.
    public var tabs: [CLITabInfo]?
    /// Populated by `windows`.
    public var windows: [CLIWindowInfo]?

    public init(
        ok: Bool,
        error: String? = nil,
        message: String? = nil,
        profiles: [CLIProfileInfo]? = nil,
        tabs: [CLITabInfo]? = nil,
        windows: [CLIWindowInfo]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.message = message
        self.profiles = profiles
        self.tabs = tabs
        self.windows = windows
    }

    public static func failure(_ error: String) -> CLIResponse {
        CLIResponse(ok: false, error: error)
    }
}

/// One profile, as reported by the `profiles` command -- mirrors the app's
/// own `Profile` (Sources/App/Profile.swift) plus `windowCount`, which only
/// the running app (not a disk read of `profiles.json`) can know.
public struct CLIProfileInfo: Codable {
    public let id: String
    public let name: String
    public let colorHex: String
    public let windowCount: Int

    public init(id: String, name: String, colorHex: String, windowCount: Int) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.windowCount = windowCount
    }
}

/// One open tab, as reported by the `tabs` command. `windowIndex`/`tabIndex`
/// are positions in the running app's current in-memory window/tab arrays
/// (`WindowManager.shared.windowControllers`/`BrowserWindowController.tabs`)
/// at the moment of the request -- stable for display purposes, not a
/// persistent identifier across requests (a tab closing shifts every later
/// index, exactly like the arrays they're read from).
public struct CLITabInfo: Codable {
    public let profileName: String
    public let windowIndex: Int
    public let tabIndex: Int
    public let isActive: Bool
    public let title: String
    public let url: String

    public init(profileName: String, windowIndex: Int, tabIndex: Int, isActive: Bool, title: String, url: String) {
        self.profileName = profileName
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.isActive = isActive
        self.title = title
        self.url = url
    }
}

/// One open window, as reported by the `windows` command. `windowIndex`
/// carries the same caveats as `CLITabInfo`'s: a position among the windows
/// actually listed (so a `--profile`-filtered listing renumbers from 0),
/// valid at the moment of the request, not a persistent identifier.
///
/// `isPrivate` windows report a synthetic per-window profile (see
/// `WindowManager.openNewPrivateWindow`) whose id/name are not real profiles
/// and will never appear in `profiles` output -- the flag is what tells a
/// caller not to treat `profileName` as addressable.
public struct CLIWindowInfo: Codable {
    public let profileName: String
    public let profileId: String
    public let windowIndex: Int
    public let tabCount: Int
    public let isPrivate: Bool
    public let activeTabTitle: String
    public let activeTabURL: String

    public init(
        profileName: String,
        profileId: String,
        windowIndex: Int,
        tabCount: Int,
        isPrivate: Bool,
        activeTabTitle: String,
        activeTabURL: String
    ) {
        self.profileName = profileName
        self.profileId = profileId
        self.windowIndex = windowIndex
        self.tabCount = tabCount
        self.isPrivate = isPrivate
        self.activeTabTitle = activeTabTitle
        self.activeTabURL = activeTabURL
    }
}
