import Foundation

/// Turns a suggestion endpoint's response body into query strings.
///
/// Every engine offered here answers in OpenSearch suggestion format --
/// `["typed", ["first", "second"]]` -- so one parser covers all of them.
/// DuckDuckGo's endpoint also has an object form (`[{"phrase": "first"}]`)
/// that it returns when the `type=list` parameter is dropped, and that is
/// accepted too rather than failing silently if the parameter is ever lost.
public enum SearchSuggestionParser {
    /// More rows than this would push the history results out of a dropdown
    /// that shows six at a time.
    public static let maxSuggestions = 5

    public static func parse(_ data: Data, query: String, limit: Int = maxSuggestions) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return clean(rawTerms(from: json), query: query, limit: limit)
    }

    private static func rawTerms(from json: Any) -> [String] {
        guard let array = json as? [Any] else { return [] }
        if array.count >= 2, let terms = array[1] as? [String] { return terms }
        if let objects = array as? [[String: Any]] {
            return objects.compactMap { $0["phrase"] as? String }
        }
        return []
    }

    /// Drops blanks, drops a suggestion identical to what was typed (the
    /// omnibox's own "search for this" row already offers that), and
    /// de-duplicates case-insensitively while keeping the engine's ranking.
    private static func clean(_ terms: [String], query: String, limit: Int) -> [String] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, key != typed, seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }
}
