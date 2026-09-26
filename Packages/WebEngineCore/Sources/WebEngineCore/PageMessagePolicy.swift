import Foundation

/// Who sent a page message, as reported by the engine itself -- never by
/// the page. CEF fills it from the `CefFrame` the query arrived on, WebKit
/// from `WKScriptMessage.frameInfo`.
public struct PageMessageSource: Equatable, Sendable {
    public let isMainFrame: Bool
    /// The sending frame's document URL.
    public let frameURL: String
    /// The sending frame's security origin, or nil when it is not an
    /// http(s) origin (opaque, file:, data:, ...).
    public let origin: WebOrigin?

    public init(isMainFrame: Bool, frameURL: String, origin: WebOrigin?) {
        self.isMainFrame = isMainFrame
        self.frameURL = frameURL
        self.origin = origin
    }

    /// For an engine that reports only the frame's URL (CEF): the origin is
    /// the URL's own.
    public init(isMainFrame: Bool, frameURL: String) {
        self.init(isMainFrame: isMainFrame, frameURL: frameURL, origin: WebOrigin(urlString: frameURL))
    }
}

/// Which frames may send a given page-message type.
public enum PageMessageFrameRule: Equatable, Sendable {
    /// The tab's main frame, on an http(s) origin that agrees with the
    /// tab's committed URL.
    case mainFrame
    /// The tab's main frame while it shows the app's own start page, and
    /// only that exact document.
    case startPage
}

/// What the tab itself says it is showing, for cross-checking a message's
/// engine-reported source against.
public struct PageMessageTabState: Equatable, Sendable {
    /// The engine's current URL for the tab (the start page's full data:
    /// URL while it shows it).
    public let engineURL: String
    public let isShowingStartPage: Bool

    public init(engineURL: String, isShowingStartPage: Bool) {
        self.engineURL = engineURL
        self.isShowingStartPage = isShowingStartPage
    }
}

public enum PageMessageVerdict: Equatable, Sendable {
    /// `origin` is the natively derived origin of the sender -- the only
    /// origin a handler may act on. nil for the start page.
    case allow(origin: WebOrigin?)
    case reject(reason: String)
}

/// The gate every page message passes before any feature sees it. A
/// message is only as trustworthy as the frame that sent it, and any frame
/// -- a cross-origin ad iframe included -- can call `cefQuery`, so the
/// decision is made here from engine-reported facts, never from the JSON.
public enum PageMessagePolicy {
    /// Every type a feature registers for. Nothing is allowed from a
    /// subframe: each of these either acts for "the site in the address
    /// bar" (passwords, card/address saving, email suggestions, notifications, reading-list
    /// capture) or is the app's own UI (the start page).
    public static let rules: [String: PageMessageFrameRule] = [
        "passwordFormSubmit": .mainFrame,
        "passwordCredentialCandidate": .mainFrame,
        "passwordFieldsPresent": .mainFrame,
        "autofillFieldFocused": .mainFrame,
        "autofillFieldBlurred": .mainFrame,
        "paymentFormSubmit": .mainFrame,
        "addressFormSubmit": .mainFrame,
        "emailFieldFocused": .mainFrame,
        "emailFieldInput": .mainFrame,
        "emailFieldBlurred": .mainFrame,
        "emailFieldSubmitted": .mainFrame,
        "notificationShow": .mainFrame,
        "notificationWaitForEvent": .mainFrame,
        "notificationClose": .mainFrame,
        "readingListArticle": .mainFrame,
        "openStartPageSettings": .startPage,
    ]

    /// A type missing from `rules` gets the strictest ordinary rule.
    public static func rule(forType type: String) -> PageMessageFrameRule {
        rules[type] ?? .mainFrame
    }

    public static func evaluate(type: String, source: PageMessageSource, tab: PageMessageTabState) -> PageMessageVerdict {
        guard source.isMainFrame else { return .reject(reason: "sent from a subframe") }
        switch rule(forType: type) {
        case .startPage:
            guard tab.isShowingStartPage,
                  source.frameURL.lowercased().hasPrefix("data:"),
                  source.frameURL == tab.engineURL
            else { return .reject(reason: "not the start page document") }
            return .allow(origin: nil)
        case .mainFrame:
            guard !tab.isShowingStartPage else { return .reject(reason: "sent while the start page is showing") }
            guard let origin = source.origin else { return .reject(reason: "sender has no http(s) origin") }
            // The engine's origin must agree with the frame's own URL (a
            // mismatch means an inherited or opaque origin) and with what the
            // tab has committed (a mismatch means the message raced a
            // navigation and belongs to a document that is no longer, or not
            // yet, the one on screen).
            guard WebOrigin(urlString: source.frameURL) == origin else {
                return .reject(reason: "frame origin does not match its URL")
            }
            guard WebOrigin(urlString: tab.engineURL) == origin else {
                return .reject(reason: "frame origin does not match the tab's URL")
            }
            return .allow(origin: origin)
        }
    }
}
