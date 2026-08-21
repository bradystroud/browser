import Foundation

/// What the user meant by what they typed into the omnibox.
public enum OmniboxIntent: Equatable {
    /// An absolute URL, ready to hand to the engine. Scheme-less input has
    /// already had a scheme added.
    case url(String)
    /// Search terms, exactly as typed (minus any forcing prefix). Turning
    /// these into a URL is `SearchEngine.searchURL(for:)`'s job, because it
    /// depends on which engine is selected and this type does not.
    case search(String)
    /// Nothing to do: the input was empty or only whitespace.
    case empty
}

/// "Is this typed text a URL or a search?" -- the omnibox's single most
/// error-prone decision, kept here as pure logic so it can be tested against
/// the awkward cases (bare hostnames, `localhost:3000`, IP literals, a query
/// with a dot or a slash in it, IDN, `about:`/`view-source:`) rather than
/// eyeballed.
///
/// The rules follow Chromium's omnibox where they are settled, because that
/// is the behavior a browser user already has in their fingers. Where
/// Chromium is ambiguous, this errs toward searching: a search for something
/// that was meant as a URL costs one extra click, while navigating to
/// something that was meant as a search sends the user to a stranger's
/// server.
public enum OmniboxInputClassifier {
    /// Typing this first forces the rest to be searched, however URL-like it
    /// looks -- the standard way to search for a literal domain name.
    private static let forceSearchPrefix: Character = "?"

    /// Schemes with no `//` authority that still name something to open.
    /// `view-source:` and `about:` matter most here: both are typed by hand,
    /// and neither survives the hostname rules further down.
    private static let opaqueNavigableSchemes: Set<String> = [
        "about", "view-source", "mailto", "tel", "sms", "facetime",
        "webcal", "magnet", "chrome", "devtools", "blob", "itms-apps",
    ]

    /// Schemes an address bar must never navigate to, whoever typed them.
    /// `javascript:` in an address bar is the classic self-XSS delivery
    /// vector -- a user is talked into pasting script that then runs with
    /// the current page's origin -- and Chrome blocks top-level `data:`
    /// navigation for the same "looks like a real site, is not one" reason.
    /// Both are classified as a search instead of being refused outright, so
    /// the input still does something visible rather than silently failing.
    private static let refusedSchemes: Set<String> = ["javascript", "data", "vbscript"]

    /// Characters that cannot appear in a hostname. Whitespace is excluded
    /// earlier and so is not repeated here.
    private static let forbiddenHostScalars = CharacterSet(charactersIn: "<>\"{}|\\^`")

    public static func classify(_ text: String) -> OmniboxIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        if trimmed.first == forceSearchPrefix {
            let forced = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return forced.isEmpty ? .empty : .search(forced)
        }

        if let (scheme, rest) = splitScheme(trimmed) {
            if refusedSchemes.contains(scheme) { return .search(trimmed) }
            // A real `scheme://host` form, including schemes we have never
            // heard of: `zoommtg://`, `slack://` and friends are handed to
            // the system, and guessing which ones exist is not this type's
            // job. "https://" with nothing after it is not one of these.
            if rest.hasPrefix("//") { return rest.count > 2 ? .url(trimmed) : .search(trimmed) }
            if opaqueNavigableSchemes.contains(scheme), !rest.isEmpty { return .url(trimmed) }
            // `localhost:3000` and `example.com:8080` parse as scheme + rest
            // but mean host + port. The giveaway is a numeric remainder.
            if let normalized = hostPortURL(host: scheme, rest: rest) { return .url(normalized) }
            // Anything else with a colon ("foo:bar") falls through to the
            // hostname rules, which reject it and search instead.
        }

        // A URL cannot contain a space, so by here any whitespace settles it.
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .search(trimmed) }

        let authority = String(trimmed.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
        // An `@` with no scheme is far more often an email address than a
        // URL with credentials in it. `https://user:pass@host` still works:
        // it took the `scheme://` path above and never reaches here.
        guard !authority.contains("@") else { return .search(trimmed) }
        guard let host = navigableHost(in: authority) else { return .search(trimmed) }
        return .url(defaultScheme(for: host, authority: authority) + "://" + trimmed)
    }

    // MARK: - Scheme

    /// Splits `scheme:rest` per RFC 3986's scheme grammar, which allows
    /// `.` -- so "example.com:8080" splits too, and `hostPortURL` sorts out
    /// what that really meant.
    private static func splitScheme(_ text: String) -> (scheme: String, rest: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = String(text[text.startIndex..<colon])
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        guard scheme.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return (scheme.lowercased(), String(text[text.index(after: colon)...]))
    }

    /// Rebuilds `host:port[/path]` into an absolute URL, or nil if `rest`
    /// isn't a port at all.
    private static func hostPortURL(host: String, rest: String) -> String? {
        let portText = String(rest.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
        guard isValidPort(portText) else { return nil }
        guard let validated = navigableHost(in: host) else { return nil }
        let scheme = portText == "443" && validated != "localhost" ? "https" : "http"
        return scheme + "://" + host + ":" + rest
    }

    private static func isValidPort(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        guard let port = Int(text) else { return false }
        return port > 0 && port <= 65535
    }

    // MARK: - Host

    /// Returns the host from an authority when that host is worth navigating
    /// to, or nil when the text should be searched instead.
    private static func navigableHost(in authority: String) -> String? {
        var host = authority

        // Bracketed IPv6 first: it is the one host form that legitimately
        // contains colons, so the port split below would mangle it.
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let inner = String(host[host.index(after: host.startIndex)..<close])
            guard isIPv6(inner) else { return nil }
            let after = String(host[host.index(after: close)...])
            if after.isEmpty { return host }
            guard after.hasPrefix(":"), isValidPort(String(after.dropFirst())) else { return nil }
            return String(host[host.startIndex...close])
        }

        if let colon = host.lastIndex(of: ":") {
            let port = String(host[host.index(after: colon)...])
            guard isValidPort(port) else { return nil }
            host = String(host[host.startIndex..<colon])
        }

        guard !host.isEmpty else { return nil }
        guard host.rangeOfCharacter(from: forbiddenHostScalars) == nil else { return nil }

        // A single trailing dot is a fully-qualified name ("example.com."),
        // not an empty label.
        var labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.count > 1, labels.last == "" { labels.removeLast() }
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }

        if labels.count == 1 {
            // A bare word is only ever a host when it is one we know names a
            // machine. "swift", "and", "r/programming" are searches.
            return isLocalhost(labels[0]) ? host : nil
        }
        if isIPv4(labels) { return host }
        // "3.14" and "1.2.3.4.5" end in digits and are not addresses, so
        // they are searches. Everything else needs a plausible TLD.
        guard let last = labels.last, looksLikeTLD(last) else { return nil }
        return host
    }

    private static func isLocalhost(_ label: String) -> Bool {
        label.lowercased() == "localhost"
    }

    private static func looksLikeTLD(_ label: String) -> Bool {
        if label.lowercased().hasPrefix("xn--") { return label.count > 4 }
        guard label.count >= 2 else { return false }
        return label.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    private static func isIPv4(_ labels: [String]) -> Bool {
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 3, label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(label) else { return false }
            return value <= 255
        }
    }

    /// Deliberately loose: enough to tell an IPv6 literal from a typo, not a
    /// full parser. Anything shaped like hex groups separated by colons, with
    /// at most one `::` elision, counts.
    private static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":") else { return false }
        guard text.components(separatedBy: "::").count <= 2 else { return false }
        let groups = text.components(separatedBy: ":").filter { !$0.isEmpty }
        guard groups.count <= 8 else { return false }
        return groups.allSatisfy { group in
            group.count <= 4 && group.allSatisfy { $0.isHexDigit && $0.isASCII }
        }
    }

    /// `https` for the public web, `http` for the places that have no
    /// certificate: a development server on localhost, an IP literal on a
    /// LAN, or any explicitly typed port other than 443. Defaulting those to
    /// `https` turns a working address into a connection error.
    private static func defaultScheme(for host: String, authority: String) -> String {
        if let colon = authority.lastIndex(of: ":"), !authority.hasPrefix("[") {
            let port = String(authority[authority.index(after: colon)...])
            if isValidPort(port) { return port == "443" ? "https" : "http" }
        }
        if authority.hasPrefix("[") { return "http" }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        if isLocalhost(bare) || bare.hasSuffix(".localhost") { return "http" }
        if isIPv4(bare.split(separator: ".", omittingEmptySubsequences: false).map(String.init)) { return "http" }
        return "https"
    }
}
