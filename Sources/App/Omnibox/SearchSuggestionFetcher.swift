import Foundation

/// Fetches live search suggestions from the selected engine's suggestion
/// endpoint (browser-0du), debounced and cancel-in-flight so typing produces
/// one request per pause rather than one per keystroke.
///
/// **This type sends what the user is typing to a third party.** Nothing
/// here decides whether that is allowed: the caller
/// (OmniboxAutocompleteController) checks the opt-in setting and the
/// window's private flag first, and this class refuses on its own only for
/// input that would be pointless or careless to send at all -- an empty or
/// one-character query, and anything that already parses as a URL.
///
/// The session is deliberately hostile to being tracked: ephemeral, cookies
/// off in both directions, no cache. A suggestion request therefore cannot
/// carry the user's signed-in identity at the search engine, so the queries
/// arrive unattached to an account even when the same engine is signed in
/// to in a tab.
final class SearchSuggestionFetcher {
    /// Long enough that a fluent typist produces one request per word, short
    /// enough that a pause feels answered immediately.
    private static let debounceInterval: TimeInterval = 0.15

    /// A single character matches most of the internet and is more often the
    /// start of a URL than a real query.
    private static let minimumQueryLength = 2

    /// One for the whole app rather than one per fetcher (there is a fetcher
    /// per window): a URLSession holds its delegate queue and connection
    /// pool until it is invalidated, and nothing ever invalidates these.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A suggestion nobody is waiting for any more is worse than no
        // suggestion, so these give up quickly.
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return URLSession(configuration: configuration)
    }()

    private var pendingRequest: DispatchWorkItem?
    private var inFlight: URLSessionDataTask?

    /// Asks for suggestions for `query`, calling `completion` on the main
    /// queue with the parsed terms. Supersedes any earlier request: an
    /// answer only ever arrives for the most recent call.
    func fetch(query: String, engine: SearchEngine, completion: @escaping ([String]) -> Void) {
        cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return }
        // Never hand the engine something the omnibox would have navigated
        // to: it produces no useful suggestion, and a URL is the most
        // sensitive thing a person types into an address bar.
        if case .url = OmniboxInputClassifier.classify(trimmed) { return }
        guard let urlString = engine.suggestURL(for: trimmed), let url = URL(string: urlString) else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let task = Self.session.dataTask(with: url) { data, _, _ in
                guard let data else { return }
                let terms = SearchSuggestionParser.parse(data, query: trimmed)
                guard !terms.isEmpty else { return }
                DispatchQueue.main.async { completion(terms) }
            }
            self.inFlight = task
            task.resume()
        }
        pendingRequest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Drops both the debounce timer and any request already on the wire --
    /// called on every new keystroke and whenever the dropdown closes.
    func cancel() {
        pendingRequest?.cancel()
        pendingRequest = nil
        inFlight?.cancel()
        inFlight = nil
    }
}
