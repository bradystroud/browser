import Foundation

/// A site the user has searched before, remembered so that typing its
/// keyword and then a query searches it directly -- Safari's Quick Website
/// Search.
public struct QuickSiteSearchSite: Equatable, Sendable {
    /// What the user types as the first word. Lowercase, derived from the
    /// host (see `QuickSiteSearch.keyword(forHost:)`).
    public let keyword: String
    public let host: String
    /// The site's own search URL with the query replaced by
    /// `SearchEngine.placeholder`.
    public let template: String
    /// How often the site has been searched, used to break a tie when a
    /// typed prefix matches more than one keyword.
    public let useCount: Int

    public init(keyword: String, host: String, template: String, useCount: Int = 1) {
        self.keyword = keyword
        self.host = host
        self.template = template
        self.useCount = useCount
    }
}

public struct QuickSiteSearchMatch: Equatable, Sendable {
    public let site: QuickSiteSearchSite
    public let query: String
    public let url: String
}

/// Deriving site-search templates from visited URLs, and matching a typed
/// "keyword query" against them. Pure logic: where the sites are stored and
/// when a visit is recorded are the app's problem, not this type's.
public enum QuickSiteSearch {
    /// Query parameter names that actually carry a search term. Kept short
    /// and deliberate: a permissive list turns every `?s=1` tracking
    /// parameter into a bogus site-search keyword, and a wrong keyword is
    /// worse than a missing one because it hijacks a word the user types.
    /// `p` is deliberately absent: it is WordPress's post id (`?p=123`).
    private static let searchParameters: Set<String> = [
        "q", "query", "search", "search_query", "searchterm", "keywords", "k", "wd", "text",
    ]

    /// Second-level labels that are part of a public suffix rather than a
    /// site name ("amazon.co.uk"). An approximation of the Public Suffix
    /// List, which is not worth vendoring for a keyword suggestion.
    private static let secondLevelSuffixes: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu"]

    /// The shortest search term worth learning a template from. One
    /// character is more often a stray parameter than a search.
    private static let minimumTermLength = 2

    /// Reads a visited URL and, if it looks like a site's own search results
    /// page, returns the site to remember. Returns nil for anything else --
    /// which is the overwhelming majority of visits.
    public static func site(fromVisitedURL urlString: String) -> QuickSiteSearchSite? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              let items = components.queryItems, !items.isEmpty else { return nil }

        guard let index = items.firstIndex(where: {
            searchParameters.contains($0.name.lowercased())
                && ($0.value?.count ?? 0) >= minimumTermLength
        }) else { return nil }

        var templateComponents = components
        templateComponents.fragment = nil
        var templateItems = items
        templateItems[index] = URLQueryItem(name: items[index].name, value: SearchEngine.placeholder)
        templateComponents.queryItems = templateItems
        guard let template = templateComponents.string else { return nil }

        // URLComponents percent-encodes the braces, which would then be
        // encoded a second time when the real query is substituted in.
        let readable = template
            .replacingOccurrences(of: "%7BsearchTerms%7D", with: SearchEngine.placeholder)
            .replacingOccurrences(of: "%7bsearchTerms%7d", with: SearchEngine.placeholder)
        guard let keyword = keyword(forHost: host) else { return nil }
        return QuickSiteSearchSite(keyword: keyword, host: host, template: readable)
    }

    /// The word the user will type: the site's name, with `www.` and the
    /// public suffix taken off. "en.wikipedia.org" becomes "wikipedia",
    /// "amazon.co.uk" becomes "amazon".
    public static func keyword(forHost host: String) -> String? {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count >= 2 else { return labels.first.flatMap { $0.isEmpty ? nil : $0 } }
        labels.removeLast()
        if labels.count >= 2, let last = labels.last, secondLevelSuffixes.contains(last) {
            labels.removeLast()
        }
        guard let keyword = labels.last, !keyword.isEmpty else { return nil }
        return keyword
    }

    /// `sites` without the search engine's own site. Its results pages are
    /// the most-visited search pages in any history, so it would otherwise
    /// always be learned -- and then "go fund me" becomes a search for
    /// "fund me" through the prefix match, instead of the search it is.
    public static func sites(_ sites: [QuickSiteSearchSite], excludingEngine engine: SearchEngine) -> [QuickSiteSearchSite] {
        guard let url = engine.searchURL(for: "x"),
              let host = URLComponents(string: url)?.host,
              let engineKeyword = keyword(forHost: host) else { return sites }
        return sites.filter { $0.keyword != engineKeyword }
    }

    /// Matches "keyword rest of the query" against known sites. Returns nil
    /// unless the first word names a site and something follows it, so
    /// ordinary searches that happen to start with a site's name ("github"
    /// on its own) are untouched.
    public static func match(input: String, sites: [QuickSiteSearchSite]) -> QuickSiteSearchMatch? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let token = trimmed[trimmed.startIndex..<space].lowercased()
        let query = String(trimmed[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !query.isEmpty else { return nil }

        guard let site = bestSite(forToken: token, sites: sites),
              let url = SearchEngine.fill(template: site.template, with: query) else { return nil }
        return QuickSiteSearchMatch(site: site, query: query, url: url)
    }

    /// An exact keyword always wins. Failing that a typed prefix counts, so
    /// "wiki foo" reaches wikipedia -- resolved by use count, then
    /// alphabetically, so the same input always picks the same site.
    private static func bestSite(forToken token: String, sites: [QuickSiteSearchSite]) -> QuickSiteSearchSite? {
        if let exact = sites.filter({ $0.keyword == token }).max(by: rank) { return exact }
        return sites.filter { $0.keyword.hasPrefix(token) }.max(by: rank)
    }

    private static func rank(_ lhs: QuickSiteSearchSite, _ rhs: QuickSiteSearchSite) -> Bool {
        lhs.useCount == rhs.useCount ? lhs.keyword > rhs.keyword : lhs.useCount < rhs.useCount
    }
}
