import Foundation

/// The site a saved password belongs to, and the rule for which pages it
/// may be filled into or matched against.
///
/// Passwords saved before origins were recorded carry only a host. For
/// those the scheme and port they were saved under are unknown, so a
/// legacy credential is treated as belonging to that host's default https
/// origin -- the overwhelmingly common case -- and is never offered to
/// plain http or to another port, where it could leak to a network
/// attacker or a different service. The one exception is loopback hosts
/// (localhost, 127.x, ::1), which never leave the machine, so local
/// development logins saved that way keep working on any port.
public enum CredentialScope: Hashable, Sendable {
    case origin(WebOrigin)
    case legacyHost(String)

    public func matches(_ pageOrigin: WebOrigin) -> Bool {
        switch self {
        case .origin(let origin):
            return origin == pageOrigin
        case .legacyHost(let host):
            guard host.lowercased() == pageOrigin.host else { return false }
            if pageOrigin.isLoopback { return true }
            return pageOrigin.scheme == "https" && pageOrigin.isDefaultPort
        }
    }

    /// An exact-origin credential beats a legacy one for the same page.
    public var matchPriority: Int {
        switch self {
        case .origin: return 1
        case .legacyHost: return 0
        }
    }

    /// What the Passwords settings pane shows for this credential.
    public var displayName: String {
        switch self {
        case .origin(let origin): return origin.serialized
        case .legacyHost(let host): return host
        }
    }

    /// The best credential for `pageOrigin` among `candidates`, or nil when
    /// none may be used there.
    public static func bestMatch<T>(for pageOrigin: WebOrigin, in candidates: [T], scope: (T) -> CredentialScope) -> T? {
        candidates
            .filter { scope($0).matches(pageOrigin) }
            .max { scope($0).matchPriority < scope($1).matchPriority }
    }
}
