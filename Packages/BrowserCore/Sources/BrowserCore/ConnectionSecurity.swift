import Foundation

/// What the site card says about how the page in front of the user arrived.
/// Pure so the classification can be tested without an engine: the engine
/// supplies what it knows about the connection, and this decides what that
/// means for the person reading it.
public enum ConnectionSecurity: Equatable, Sendable {
    /// https, a certificate the engine accepted, and nothing on the page
    /// fetched over plain http.
    case secure
    /// https with a trusted certificate, but some of the page came over
    /// plain http.
    case mixedContent
    /// https whose certificate the engine flagged as not valid.
    case certificateError
    /// https, but the engine has not (yet) said anything about the
    /// connection -- mid-navigation, or a page it has no record for. Never
    /// shown as secure: only a confirmed connection earns that.
    case unverified
    /// Plain http to somewhere other than this Mac.
    case notSecure
    /// Something with no network connection to judge: a file, this Mac's own
    /// server, an internal page.
    case local

    /// What the engine reports about the current page's connection. Every
    /// field is the engine's own view, not a guess from the URL.
    public struct EngineReport: Equatable, Sendable {
        public var isSecureConnection: Bool
        public var hasCertificateError: Bool
        public var hasInsecureContent: Bool

        public init(isSecureConnection: Bool, hasCertificateError: Bool, hasInsecureContent: Bool) {
            self.isSecureConnection = isSecureConnection
            self.hasCertificateError = hasCertificateError
            self.hasInsecureContent = hasInsecureContent
        }
    }

    /// `report` is nil when the engine has nothing to say about this page.
    public static func classify(urlString: String, report: EngineReport?) -> ConnectionSecurity {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased() else { return .local }
        switch scheme {
        case "https", "wss":
            guard let report else { return .unverified }
            if report.hasCertificateError { return .certificateError }
            guard report.isSecureConnection else { return .unverified }
            return report.hasInsecureContent ? .mixedContent : .secure
        case "http", "ws":
            // Traffic to this Mac never crosses a network anyone else can
            // read, so calling it "not secure" would only teach people to
            // ignore the warning. Chromium treats these hosts the same way.
            return isLoopback(host: components.host) ? .local : .notSecure
        default:
            return .local
        }
    }

    static func isLoopback(host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    public var title: String {
        switch self {
        case .secure: return "Connection is secure"
        case .mixedContent: return "Parts of this page are not secure"
        case .certificateError: return "Certificate is not valid"
        case .unverified: return "Connection not yet verified"
        case .notSecure: return "Connection is not secure"
        case .local: return "Local page"
        }
    }

    public var detail: String {
        switch self {
        case .secure:
            return "Information you send to this site, such as passwords or card numbers, is private in transit."
        case .mixedContent:
            return "The page arrived privately, but some of what it shows was fetched over plain http, where others on the network could read or change it."
        case .certificateError:
            return "This site's certificate isn't trusted. Someone could be impersonating the site or reading what you send."
        case .unverified:
            return "The browser hasn't confirmed this page's connection yet. Reload the page if this persists."
        case .notSecure:
            return "Don't enter passwords or card numbers here: anything sent to this site can be read on the way."
        case .local:
            return "This page didn't come over the internet."
        }
    }

    /// An SF Symbol name for the omnibox's site button and the card.
    public var symbolName: String {
        switch self {
        case .secure: return "lock.fill"
        case .mixedContent: return "lock.trianglebadge.exclamationmark.fill"
        case .certificateError, .notSecure: return "exclamationmark.triangle.fill"
        case .unverified: return "lock"
        case .local: return "info.circle"
        }
    }

    /// Whether the card should draw attention to this state.
    public var isWarning: Bool {
        switch self {
        case .mixedContent, .certificateError, .notSecure: return true
        case .secure, .unverified, .local: return false
        }
    }
}
