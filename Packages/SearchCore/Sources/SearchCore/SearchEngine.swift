import Foundation

/// Which search engine the omnibox uses for non-URL input. Persisted by raw
/// value, so these strings are a storage format -- rename one and every
/// existing install silently falls back to the default.
public enum SearchEngineChoice: String, CaseIterable, Sendable {
    case google
    case duckDuckGo = "duckduckgo"
    case bing
    case kagi
    case custom
}

/// A search engine as a pair of URL templates. Splitting the templates out
/// from `SearchEngineChoice` is what lets a custom engine and a built-in one
/// travel through the same code path.
public struct SearchEngine: Equatable, Sendable {
    /// The OpenSearch placeholder. `%s` is accepted as well, because that is
    /// what Chrome's own "add a search engine" field uses and what people
    /// therefore have to hand when they paste a template in.
    public static let placeholder = "{searchTerms}"
    private static let alternatePlaceholder = "%s"

    public let choice: SearchEngineChoice
    public let name: String
    public let searchTemplate: String
    /// nil when the engine has no suggestion endpoint we can use -- a custom
    /// engine, in practice. Suggestions are simply not offered then.
    public let suggestTemplate: String?

    public init(choice: SearchEngineChoice, name: String, searchTemplate: String, suggestTemplate: String?) {
        self.choice = choice
        self.name = name
        self.searchTemplate = searchTemplate
        self.suggestTemplate = suggestTemplate
    }

    // MARK: - Built-ins

    public static let google = SearchEngine(
        choice: .google,
        name: "Google",
        searchTemplate: "https://www.google.com/search?q={searchTerms}",
        // client=firefox is the long-standing way to ask this endpoint for
        // plain OpenSearch JSON (["query", ["a", "b"]]) rather than the
        // JSONP-ish payload the Chrome clients get.
        suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q={searchTerms}"
    )

    public static let duckDuckGo = SearchEngine(
        choice: .duckDuckGo,
        name: "DuckDuckGo",
        searchTemplate: "https://duckduckgo.com/?q={searchTerms}",
        suggestTemplate: "https://duckduckgo.com/ac/?q={searchTerms}&type=list"
    )

    public static let bing = SearchEngine(
        choice: .bing,
        name: "Bing",
        searchTemplate: "https://www.bing.com/search?q={searchTerms}",
        suggestTemplate: "https://www.bing.com/osjson.aspx?query={searchTerms}"
    )

    public static let kagi = SearchEngine(
        choice: .kagi,
        name: "Kagi",
        searchTemplate: "https://kagi.com/search?q={searchTerms}",
        suggestTemplate: "https://kagi.com/api/autosuggest?q={searchTerms}"
    )

    /// The engine used when nothing has been chosen. DuckDuckGo, not Google:
    /// it is what the omnibox already used before this setting existed, and
    /// switching everyone's default engine is not a thing to do silently.
    public static let `default` = duckDuckGo

    public static let builtIns: [SearchEngine] = [google, duckDuckGo, bing, kagi]

    public static func builtIn(_ choice: SearchEngineChoice) -> SearchEngine? {
        builtIns.first { $0.choice == choice }
    }

    /// A user-supplied template. Returns nil unless the template is one we
    /// can actually search with -- see `isValidTemplate`.
    public static func custom(template: String) -> SearchEngine? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidTemplate(trimmed) else { return nil }
        return SearchEngine(
            choice: .custom,
            name: customName(for: trimmed),
            searchTemplate: trimmed,
            // No way to discover a site's suggestion endpoint from its search
            // URL, so a custom engine simply has none.
            suggestTemplate: nil
        )
    }

    /// A template is usable when it has somewhere to put the query and
    /// resolves to an http(s) URL with a host. The scheme restriction is the
    /// same footgun guard the homepage field applies: a template is stored
    /// once and then followed on every search.
    public static func isValidTemplate(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(placeholder) || trimmed.contains(alternatePlaceholder) else { return false }
        guard let filled = fill(template: trimmed, with: "test"),
              let url = URL(string: filled),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !(url.host?.isEmpty ?? true) else { return false }
        return true
    }

    /// The host, as a stand-in name for a custom engine, so the settings
    /// popup can say "example.com" rather than "Custom".
    private static func customName(for template: String) -> String {
        guard let filled = fill(template: template, with: "test"),
              let host = URL(string: filled)?.host else { return "Custom" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - URLs

    public func searchURL(for query: String) -> String? {
        Self.fill(template: searchTemplate, with: query)
    }

    public func suggestURL(for query: String) -> String? {
        guard let suggestTemplate else { return nil }
        return Self.fill(template: suggestTemplate, with: query)
    }

    /// Substitutes the query into a template, percent-encoding it as an
    /// opaque blob. Only the RFC 3986 unreserved set survives: encoding
    /// `&`, `=`, `#` and `+` is the whole point, or a query containing them
    /// would rewrite the template's own parameters.
    public static func fill(template: String, with query: String) -> String? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        guard template.contains(placeholder) || template.contains(alternatePlaceholder) else { return nil }
        return template
            .replacingOccurrences(of: placeholder, with: encoded)
            .replacingOccurrences(of: alternatePlaceholder, with: encoded)
    }
}
