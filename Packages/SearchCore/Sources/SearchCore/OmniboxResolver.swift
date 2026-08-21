import Foundation

/// What pressing Return in the omnibox should do.
public enum OmniboxResolution: Equatable {
    case navigate(String)
    /// The input was empty: do nothing at all rather than navigate somewhere.
    case nothing
}

/// Puts the three decisions together -- URL or search, which engine, and
/// whether a Quick Website Search keyword claims the input -- in the one
/// order they have to happen in.
public enum OmniboxResolver {
    public static func resolve(
        input: String,
        engine: SearchEngine,
        quickSites: [QuickSiteSearchSite] = []
    ) -> OmniboxResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch OmniboxInputClassifier.classify(trimmed) {
        case .empty:
            return .nothing
        case .url(let resolved):
            return .navigate(resolved)
        case .search(let query):
            // A leading "?" means "search this, whatever it looks like",
            // which includes not letting a site keyword claim it.
            if !trimmed.hasPrefix("?"),
               let match = QuickSiteSearch.match(input: query, sites: quickSites) {
                return .navigate(match.url)
            }
            guard let url = engine.searchURL(for: query) else { return .nothing }
            return .navigate(url)
        }
    }
}
