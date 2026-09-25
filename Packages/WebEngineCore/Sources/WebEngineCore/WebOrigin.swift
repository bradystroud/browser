import Foundation

/// An http(s) origin -- scheme, host and effective port -- as the web
/// platform defines it, and the unit every security decision in the app
/// compares: which site sent a page message, which site a saved password
/// belongs to, which site a popup may open a blob from.
///
/// Only the two tuple origins the app ever trusts are representable. Every
/// other scheme (file:, data:, about:, a sandboxed frame's opaque origin)
/// has no `WebOrigin`, so code that needs one fails closed on them.
///
/// The port is always stored explicitly (443/80 when the URL omits it), so
/// `https://a.com` and `https://a.com:443` are the same origin while
/// `https://a.com:8443` is not.
public struct WebOrigin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    /// `port` nil or 0 means the scheme's default -- WKSecurityOrigin
    /// reports 0 for "no explicit port".
    public init?(scheme: String, host: String, port: Int?) {
        let scheme = scheme.lowercased()
        guard let defaultPort = Self.defaultPort(forScheme: scheme) else { return nil }
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        let port = (port == nil || port == 0) ? defaultPort : port!
        guard (1...65535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// The origin of `urlString`, or nil when it has no http(s) origin.
    /// A `blob:` URL carries its creator's origin inside it
    /// (`blob:https://a.com/<uuid>`), which is what this returns for one.
    public init?(urlString: String) {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        if scheme == "blob" {
            let inner = String(urlString.dropFirst("blob:".count))
            guard !inner.lowercased().hasPrefix("blob:") else { return nil }
            self.init(urlString: inner)
            return
        }
        guard let host = components.host else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    public static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    public var isDefaultPort: Bool { port == Self.defaultPort(forScheme: scheme) }

    /// The ASCII serialization `location.origin` produces: no trailing
    /// slash, the port only when it isn't the scheme's default.
    public var serialized: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return isDefaultPort ? "\(scheme)://\(hostPart)" : "\(scheme)://\(hostPart):\(port)"
    }

    public var description: String { serialized }

    /// localhost and the loopback addresses -- traffic that never leaves
    /// the machine.
    public var isLoopback: Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }
}
