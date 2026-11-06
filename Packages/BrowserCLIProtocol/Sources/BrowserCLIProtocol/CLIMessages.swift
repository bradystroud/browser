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

    /// The agent page a `page` command acted on.
    public var page: CLIPageInfo?
    /// Populated by `page list`.
    public var pages: [CLIPageInfo]?
    /// Populated by `page snapshot`.
    public var snapshot: CLIPageSnapshot?
    /// Populated by `page eval`: the expression's JSON value.
    public var value: CLIJSONValue?
    /// The element a `page click`/`type`/`hover`/`select` acted on.
    public var element: CLIPageElement?
    /// A file or directory `page screenshot`/`page record` wrote.
    public var path: String?
    /// Populated by `page record stop`: how many frames were written.
    public var frameCount: Int?
    /// What an agent page did on its own during a `page` command: dialogs
    /// answered and file choosers opened.
    public var pageEvents: [String]?
    /// How many elements a `page click`/`hover`/`type`/`select` target
    /// matched; the best-ranked one was used.
    public var matches: Int?

    public init(
        ok: Bool,
        error: String? = nil,
        message: String? = nil,
        profiles: [CLIProfileInfo]? = nil,
        tabs: [CLITabInfo]? = nil,
        windows: [CLIWindowInfo]? = nil,
        page: CLIPageInfo? = nil,
        pages: [CLIPageInfo]? = nil,
        snapshot: CLIPageSnapshot? = nil,
        value: CLIJSONValue? = nil,
        element: CLIPageElement? = nil,
        path: String? = nil,
        frameCount: Int? = nil,
        pageEvents: [String]? = nil,
        matches: Int? = nil
    ) {
        self.ok = ok
        self.error = error
        self.message = message
        self.profiles = profiles
        self.tabs = tabs
        self.windows = windows
        self.page = page
        self.pages = pages
        self.snapshot = snapshot
        self.value = value
        self.element = element
        self.path = path
        self.frameCount = frameCount
        self.pageEvents = pageEvents
        self.matches = matches
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
    /// True while the tab holds no loaded page (never selected since launch,
    /// or put to sleep). Optional so a CLI and an app from different builds
    /// still understand each other; nil means the app didn't say.
    public let isAsleep: Bool?
    /// The engine the tab's page is in (or will be created in): `cef` or
    /// `webkit`. Optional for the same reason as `isAsleep`.
    public let engine: String?

    public init(profileName: String, windowIndex: Int, tabIndex: Int, isActive: Bool, title: String, url: String, isAsleep: Bool? = nil, engine: String? = nil) {
        self.profileName = profileName
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.isActive = isActive
        self.title = title
        self.url = url
        self.isAsleep = isAsleep
        self.engine = engine
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

/// A window an agent opened with `browser page open` -- the only windows the
/// `page` commands can reach. `id` is short and stays the same until the
/// window closes; commands act on that window's visible tab.
public struct CLIPageInfo: Codable {
    public let id: String
    public let profileName: String
    public let isPrivate: Bool
    public let url: String
    public let title: String
    public let isLoading: Bool
    /// The window is off screen and out of the Window menu and Mission
    /// Control; `page show` brings it on screen.
    public let isHeadless: Bool?
    /// The engine the page is in ("cef" or "webkit"), picked by the engine
    /// rules when it opened. An agent's page never changes engine.
    public let engine: String?

    public init(id: String, profileName: String, isPrivate: Bool, url: String, title: String, isLoading: Bool, isHeadless: Bool? = nil, engine: String? = nil) {
        self.id = id
        self.profileName = profileName
        self.isPrivate = isPrivate
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.isHeadless = isHeadless
        self.engine = engine
    }
}

/// What `page snapshot` read: the page's visible text and the elements a
/// user could act on, each with a `ref` that later commands accept.
public struct CLIPageSnapshot: Codable {
    public let url: String
    public let title: String
    public let text: String
    public let textTruncated: Bool
    public let elements: [CLIPageElement]
    public let elementsTruncated: Bool
    public let viewportWidth: Double
    public let viewportHeight: Double

    public init(url: String, title: String, text: String, textTruncated: Bool, elements: [CLIPageElement], elementsTruncated: Bool, viewportWidth: Double, viewportHeight: Double) {
        self.url = url
        self.title = title
        self.text = text
        self.textTruncated = textTruncated
        self.elements = elements
        self.elementsTruncated = elementsTruncated
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}

/// One element of a page. `ref` (e.g. "e12") stays bound to the same element
/// for as long as the document keeps it. A password field never carries a
/// `value`.
public struct CLIPageElement: Codable {
    public let ref: String
    public let role: String
    public let name: String
    public let tag: String
    public let type: String?
    public let value: String?
    public let checked: Bool?
    public let disabled: Bool?
    public let inViewport: Bool
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// The element's `title` (or its nearest ancestor's): what a hover
    /// shows as a native tooltip, which no screenshot captures.
    public let title: String?
    /// The text of the elements `aria-describedby` points at.
    public let description: String?
    /// Its `aria-keyshortcuts`.
    public let shortcut: String?
}

/// Any JSON value, so `page eval` can hand back exactly what the page
/// returned.
public enum CLIJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CLIJSONValue])
    case object([String: CLIJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CLIJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CLIJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// From a JSONSerialization value. Anything it cannot represent is null.
    public init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { CLIJSONValue(foundation: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { CLIJSONValue(foundation: $0) })
        default: self = .null
        }
    }
}
