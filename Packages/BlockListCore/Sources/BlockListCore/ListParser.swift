import Foundation

/// Parses two curated-blocklist formats: a hosts-file (StevenBlack-style:
/// `0.0.0.0 ads.example.com`, one or more hostnames per line, `#` comments,
/// blank lines) and a plain domain-per-line list (OISD "domains only"
/// style: just `ads.example.com`). Both formats can appear mixed in the
/// same text -- each line is classified independently.
///
/// Deliberately does **not** parse EasyList/Adblock Plus cosmetic-filter
/// syntax (`##selector`, `$third-party` options, etc.) -- that's a
/// materially different, much larger parsing problem (cosmetic
/// element-hiding rules need a CSS-rule engine, not a domain matcher), and
/// this blocker only ever blocks/allows whole requests by host. See the
/// package README for the full scope note.
public enum ListParser {
    /// Standard hosts-file boilerplate every StevenBlack-style list carries
    /// at the top for basic loopback/broadcast entries -- these are not
    /// ad/tracker domains and must never be blocked.
    private static let reservedHostnames: Set<String> = [
        "localhost", "localhost.localdomain", "local",
        "broadcasthost",
        "ip6-localhost", "ip6-loopback", "ip6-localnet",
        "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters", "ip6-allhosts",
    ]

    /// The handful of loopback/null-route addresses these lists redirect
    /// blocked domains to. A first token matching one of these is what
    /// identifies a line as hosts-file-format (address + hostname(s));
    /// anything else in the first column (a real routable IP) means the
    /// line doesn't match either recognized shape, so it's skipped rather
    /// than guessed at.
    private static let blockingRedirectAddresses: Set<String> = [
        "0.0.0.0", "127.0.0.1", "::1", "255.255.255.255",
    ]

    /// Every recognized domain across the whole (possibly mixed-format)
    /// text, in file order, including duplicates -- callers that just want
    /// to load a list should use `parse(_:into:)` instead; this is for
    /// callers (like `BlockList`) that need the actual domain strings, not
    /// just a trie populated from them.
    public static func parseDomains(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { domains(inLine: $0) }
    }

    /// Parses `text` (either format, lines may be mixed) and inserts every
    /// recognized domain into `trie`. Returns the number of *new* domains
    /// added (duplicates already in `trie` don't count), for logging/
    /// diagnostics.
    @discardableResult
    public static func parse(_ text: String, into trie: DomainTrie) -> Int {
        var added = 0
        for domain in parseDomains(text) {
            let countBefore = trie.count
            trie.insert(domain)
            if trie.count != countBefore { added += 1 }
        }
        return added
    }

    /// Every recognized, non-reserved domain on one line -- zero, one
    /// (plain format), or more (hosts-file format with multiple hostnames
    /// after the same address, standard `/etc/hosts` behavior) domains.
    static func domains(inLine rawLine: Substring) -> [String] {
        // Strip an inline "#" comment (or the whole line, if it starts
        // with one), then surrounding whitespace.
        let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let line = withoutComment.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }

        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let candidates: [String]
        if tokens.count > 1, blockingRedirectAddresses.contains(tokens[0]) {
            // Hosts-file format: "<redirect-address> <host> [<host> ...]".
            candidates = Array(tokens.dropFirst())
        } else if tokens.count == 1 {
            // Plain domain-per-line format.
            candidates = tokens
        } else {
            // Doesn't match either recognized shape (most likely: a real
            // routable IP mapped to a hostname, not a blocklist entry).
            candidates = []
        }

        return candidates
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && !reservedHostnames.contains($0) && !blockingRedirectAddresses.contains($0) }
    }
}
