import Foundation

/// Which account a sign-in page expects, as far as its own URL says.
///
/// Parsed only from the engine's verified URL for the tab, never from
/// anything a page script reports: a page can already put whatever it likes
/// in its own URL, so these are *hints* for ordering suggestions and never
/// a reason to fill anything without the user choosing it.
public struct IdentityProviderHints: Equatable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case microsoft, google, okta, auth0

        public var displayName: String {
            switch self {
            case .microsoft: return "Microsoft"
            case .google: return "Google"
            case .okta: return "Okta"
            case .auth0: return "Auth0"
            }
        }
    }

    public var provider: Provider?
    /// `login_hint` when it is a well-formed email: the page names the
    /// exact account it wants.
    public var loginHint: String?
    /// Domains the expected account belongs to: `domain_hint`, `whr`, `hd`,
    /// or a Microsoft tenant written as a domain.
    public var domainHints: [String] = []
    /// Tenant names that are not domains -- an Okta/Auth0 subdomain such as
    /// `contoso` in `contoso.okta.com` -- matched against an email domain's first
    /// label.
    public var tenantLabels: [String] = []
    /// A stable key for "this tenant", used to remember which email was last
    /// used with it: `microsoft:<guid or domain>`, `okta:<subdomain>`,
    /// `auth0:<subdomain>`, `google:<hd>`.
    public var tenantKey: String?

    public init() {}

    public var isEmpty: Bool {
        provider == nil && loginHint == nil && domainHints.isEmpty && tenantLabels.isEmpty && tenantKey == nil
    }

    private static let microsoftHosts: Set<String> = [
        "login.microsoftonline.com", "login.windows.net", "login.live.com", "login.microsoft.com",
        "login.microsoftonline.us", "login.partner.microsoftonline.cn",
    ]

    /// Path segments on the Microsoft endpoints that name an audience, not
    /// a tenant.
    private static let microsoftNonTenantSegments: Set<String> = [
        "common", "organizations", "consumers", "oauth2", "login", "login.srf", "ppsecure", "saml2", "wsfed",
        "kmsi", "appverify", "federation", "v2.0", "te",
    ]

    public static func parse(urlString: String) -> IdentityProviderHints {
        guard let components = URLComponents(string: urlString), let host = components.host?.lowercased() else {
            return IdentityProviderHints()
        }
        var hints = IdentityProviderHints()
        let query = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            let name = item.name.lowercased()
            if result[name] == nil, let value = item.value, !value.isEmpty { result[name] = value }
        }

        if let hint = query["login_hint"], let email = EmailAddress.normalized(hint) {
            hints.loginHint = email
        }
        for key in ["domain_hint", "whr", "hd"] {
            if let value = query[key], let domain = normalizedDomain(value) {
                hints.appendDomain(domain)
            }
        }

        if microsoftHosts.contains(host) {
            hints.provider = .microsoft
            let segments = components.path.split(separator: "/").map { $0.lowercased() }
            let candidates = [query["tenant"]].compactMap { $0?.lowercased() } + Array(segments.prefix(1))
            for candidate in candidates where !microsoftNonTenantSegments.contains(candidate) {
                if isGUID(candidate) {
                    hints.tenantKey = "microsoft:\(candidate)"
                    break
                }
                if let domain = normalizedDomain(candidate) {
                    hints.tenantKey = "microsoft:\(domain)"
                    hints.appendDomain(domain)
                    break
                }
            }
        } else if host == "accounts.google.com" {
            hints.provider = .google
            if let hd = hints.domainHints.first, query["hd"] != nil {
                hints.tenantKey = "google:\(hd)"
            }
        } else if let label = subdomainLabel(host: host, under: ["okta.com", "oktapreview.com", "okta-emea.com"]) {
            hints.provider = .okta
            hints.tenantKey = "okta:\(label)"
            hints.tenantLabels.append(label)
        } else if let label = subdomainLabel(host: host, under: ["auth0.com"]) {
            hints.provider = .auth0
            hints.tenantKey = "auth0:\(label)"
            hints.tenantLabels.append(label)
        }
        return hints
    }

    private mutating func appendDomain(_ domain: String) {
        if !domainHints.contains(domain) { domainHints.append(domain) }
    }

    /// The tenant label in `contoso.okta.com` or `contoso.au.auth0.com` -- always the
    /// leftmost label, whatever region labels sit between it and the base.
    private static func subdomainLabel(host: String, under bases: [String]) -> String? {
        for base in bases where host.hasSuffix("." + base) {
            let prefix = host.dropLast(base.count + 1)
            guard let first = prefix.split(separator: ".").first, !first.isEmpty else { return nil }
            return String(first)
        }
        return nil
    }

    private static func isGUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// A hint value that looks like a DNS domain (`contoso.com.au`), lowercased;
    /// nil for `organizations`, `consumers`, a GUID or anything else.
    private static func normalizedDomain(_ value: String) -> String? {
        let domain = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.count <= 253,
              domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !isGUID(domain),
              let tld = domain.split(separator: ".").last,
              tld.allSatisfy(\.isLetter),
              !["srf", "aspx", "asp", "php", "html", "htm", "jsp", "do"].contains(String(tld))
        else { return nil }
        return domain
    }
}

/// Email-address normalization shared by every source and the ranker.
public enum EmailAddress {
    /// Trimmed and lowercased when `raw` is a plausible single address
    /// (`local@domain.tld`), nil otherwise. Lowercasing the local part is
    /// technically lossy, but no mainstream provider treats it as
    /// case-sensitive, and without it one address learned twice would be
    /// suggested twice.
    public static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count <= 254, !value.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" }) else { return nil }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return nil }
        return value
    }

    /// The part after the `@`, for an already-normalized address.
    public static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return String(email[email.index(after: at)...])
    }
}
