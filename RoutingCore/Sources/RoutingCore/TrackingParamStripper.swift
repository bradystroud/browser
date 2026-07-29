import Foundation

/// Strips known tracking query parameters from a URL (browser-ymx) --
/// pure, synchronous, no network. Applied before rule matching AND before
/// actually opening a link, so a rule written against a bare URL keeps
/// matching regardless of whatever tracking params a particular shared
/// link happened to be decorated with, and Brady never sees them in the
/// address bar either. See `starterTrackingParamsText` for the curated
/// list this parses, and `URLUnshortener` (Sources/App) for the separate,
/// opt-in, network-requiring "follow shortened links" half of this
/// feature -- this file only ever touches the URL string itself.
public enum TrackingParamStripper {
    /// `exactNames` are lowercased, compared case-insensitively against a
    /// query item's name; `prefixes` are the part before a trailing `*` in
    /// the source list (also lowercased), matched as a case-insensitive
    /// prefix -- see `starterTrackingParamsText`'s own doc comment for the
    /// two entry shapes.
    private static let (exactNames, prefixes): (Set<String>, [String]) = parseList(starterTrackingParamsText)

    static func parseList(_ text: String) -> (exact: Set<String>, prefixes: [String]) {
        var exact: Set<String> = []
        var prefixes: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasSuffix("*") {
                prefixes.append(String(line.dropLast()).lowercased())
            } else {
                exact.insert(line.lowercased())
            }
        }
        return (exact, prefixes)
    }

    private static func isTrackingParam(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if exactNames.contains(lowered) { return true }
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    /// Returns `urlString` with every recognized tracking query parameter
    /// removed, preserving the order and values of everything else
    /// (including the fragment). Returns `urlString` unchanged if it has no
    /// query string, none of its parameters are recognized, or it doesn't
    /// parse as a URL at all (never corrupts an unparseable string by
    /// attempting to rebuild it).
    public static func strip(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let queryItems = components.queryItems, !queryItems.isEmpty
        else {
            return urlString
        }

        let filtered = queryItems.filter { !isTrackingParam($0.name) }
        guard filtered.count != queryItems.count else {
            // Nothing recognized -- return the original string verbatim
            // rather than a re-percent-encoded equivalent, so a URL this
            // function doesn't touch is never even cosmetically altered.
            return urlString
        }

        // nil (not []), so URLComponents.string omits the "?" entirely
        // when every query item was a tracking param -- an empty-but-
        // present query items array would instead serialize as a bare
        // trailing "?".
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }
}
