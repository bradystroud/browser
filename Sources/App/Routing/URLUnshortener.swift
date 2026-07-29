import Foundation

/// Follows a shortened link's redirect chain to its real destination
/// (browser-ymx) -- opt-in via `LinkHandlingPreferences.unshortenLinks`,
/// off by default. This is the one part of the link-handling feature that
/// needs a real network round-trip before a link even opens (unlike
/// `TrackingParamStripper`, which is pure/synchronous), which is exactly
/// why it's opt-in rather than on by default, and why `RoutingCoordinator`
/// -- the only caller -- never invokes it for a private window: routed
/// links always resolve to a real ProfileManager profile, never a private
/// one (see RoutingCoordinator.route's own doc comment), so this is safe
/// by construction rather than something needing its own runtime check
/// here.
enum URLUnshortener {
    /// Recognized shortener hosts worth the extra round-trip for -- a
    /// small, hand-curated list (same "starter, not exhaustive" framing as
    /// `TrackingParamStripper`'s own list), checked before ever making a
    /// network request: most links aren't shortened, and skipping the
    /// request entirely for a host not on this list is both faster and
    /// avoids an unnecessary hit against a server that was never going to
    /// redirect anywhere.
    static let knownShortenerHosts: Set<String> = [
        "t.co", "bit.ly", "tinyurl.com", "goo.gl", "ow.ly", "buff.ly",
        "is.gd", "lnkd.in", "rebrand.ly", "shorturl.at", "cutt.ly",
        "rb.gy", "s.id", "bl.ink", "amzn.to", "fb.me",
        "t.ly", "shorte.st", "adf.ly", "soo.gd", "clck.ru",
    ]

    /// True only for a host actually worth resolving -- see
    /// `knownShortenerHosts`'s own doc comment.
    static func isLikelyShortened(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return knownShortenerHosts.contains(host)
    }

    /// Resolves `urlString` to its final destination by issuing a HEAD
    /// request and reading back where URLSession's own automatic redirect
    /// following landed -- a short (5s) timeout, and any failure (network
    /// error, timeout, a shortener that rejects HEAD) calls back with
    /// `urlString` completely unchanged rather than blocking routing
    /// indefinitely or surfacing an error UI for what's meant to be an
    /// invisible convenience. Always calls back on the main queue.
    static func resolve(_ urlString: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(urlString)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            let resolved = (response as? HTTPURLResponse)?.url?.absoluteString ?? urlString
            DispatchQueue.main.async {
                completion(resolved)
            }
        }
        task.resume()
    }
}
