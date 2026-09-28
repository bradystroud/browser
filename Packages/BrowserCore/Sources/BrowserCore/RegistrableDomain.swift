import Foundation

/// The "site" a host belongs to -- its registrable domain (eTLD+1), so
/// `login.contoso.com.au` and `www.contoso.com.au` are the same site and
/// `contoso.com.au` / `other.com.au` are not.
///
/// A heuristic, not the Public Suffix List: it knows the second-level
/// suffixes country-code registries actually hand out (`com.au`, `co.uk`,
/// `co.nz`, ...) and treats everything else as a one-label suffix. That is
/// right for the sites people sign in to; it is wrong for private-registry
/// suffixes such as `github.io`, where two different users' pages would
/// count as one site. Nothing that depends on it is a security decision --
/// only suggestion ordering -- so the approximation is safe.
public enum RegistrableDomain {
    /// Second-level labels that registries under a two-letter country code
    /// use as a public suffix of their own (`com.au`, `co.uk`, `ne.jp`).
    private static let countrySecondLevel: Set<String> = [
        "com", "co", "net", "org", "edu", "gov", "govt", "ac", "ne", "or", "go",
        "asn", "id", "ltd", "plc", "me", "nom", "sch", "mil", "gob", "gen", "firm",
    ]

    public static func of(host rawHost: String) -> String {
        var host = rawHost.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        // An IPv4 address has no registrable part.
        if labels.allSatisfy({ Int($0) != nil }) { return host }
        let tld = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        let suffixLabels = (tld.count == 2 && countrySecondLevel.contains(second)) ? 2 : 1
        return labels.suffix(suffixLabels + 1).joined(separator: ".")
    }

    /// Whether `host` is `domain` itself or one of its subdomains.
    public static func host(_ host: String, isWithin domain: String) -> Bool {
        let host = host.lowercased(), domain = domain.lowercased()
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
