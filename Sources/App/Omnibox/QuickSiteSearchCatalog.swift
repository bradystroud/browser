import Foundation

/// The set of sites the user can reach with a Quick Website Search keyword
/// (browser-0du), derived from history rather than stored separately.
///
/// Deriving it costs a `LIKE` scan of `history_urls`, so it is built on a
/// background queue and cached per profile. Nothing here ever blocks a
/// keystroke: the omnibox asks for whatever is cached and gets an empty list
/// until the first build lands, a few tens of milliseconds after the window
/// opens. A stale catalog only ever means a site the user searched moments
/// ago is not a keyword yet.
///
/// There is no separate store and no schema migration behind this on
/// purpose. Everything it needs -- which sites have a search page, and how
/// often they were used -- is already in history, and a second copy of that
/// would be a second thing to delete when the user clears their history.
final class QuickSiteSearchCatalog {
    static let shared = QuickSiteSearchCatalog()

    /// How long a built catalog is trusted before the next request rebuilds
    /// it. A keyword the user has just created is worth waiting a minute for.
    private static let maximumAge: TimeInterval = 60

    /// Rows to consider per rebuild. A cap is what keeps the scan bounded on
    /// a large history; the rows are newest-first, so it is the recent
    /// searches that survive it -- which is what a keyword should reflect.
    private static let scanLimit = 2000

    /// A keyword only earns its place once the site has been searched more
    /// than once. A single search is as often a link someone sent as a habit,
    /// and a wrong keyword hijacks a word the user types.
    private static let minimumUseCount = 2

    /// The build runs here; the cache is guarded by `lock` instead of by
    /// this queue. Reading through `queue.sync` would park the main thread
    /// for the whole scan whenever a keystroke landed mid-build, which is
    /// exactly the case the background build exists to avoid.
    private let queue = DispatchQueue(label: "browser.quick-site-search", qos: .utility)
    private let lock = NSLock()
    private var cache: [String: [QuickSiteSearchSite]] = [:]
    private var buildStartedAt: [String: Date] = [:]
    private var building: Set<String> = []

    private init() {}

    /// The catalog for a profile, as it stands right now. Kicks off a
    /// rebuild when the cached copy is missing or stale, and returns without
    /// waiting for it. The default engine is filtered out here rather than
    /// at build time, so changing the engine takes effect on the next
    /// keystroke instead of after the next rebuild.
    func sites(profileId: String, history: HistoryStore) -> [QuickSiteSearchSite] {
        lock.lock()
        let cached = cache[profileId] ?? []
        let age = buildStartedAt[profileId].map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let needsBuild = !building.contains(profileId) && age > Self.maximumAge
        if needsBuild {
            building.insert(profileId)
            buildStartedAt[profileId] = Date()
        }
        lock.unlock()

        if needsBuild {
            queue.async { [weak self] in
                let built = Self.build(history: history)
                guard let self else { return }
                self.lock.lock()
                self.cache[profileId] = built
                self.building.remove(profileId)
                self.lock.unlock()
            }
        }
        return QuickSiteSearch.sites(cached, excludingEngine: SearchEnginePreference.current)
    }

    private static func build(history: HistoryStore) -> [QuickSiteSearchSite] {
        // "?" is the cheapest filter that keeps only URLs with a query
        // string, which is the only kind that can carry a search term.
        guard let entries = try? history.entries(matching: "?", limit: scanLimit) else { return [] }

        // Per keyword: the template from its most-visited search page (a site
        // can have several, and the one the user actually uses is the one to
        // reproduce), and the total visits across all of them.
        var best: [String: (host: String, template: String, templateUses: Int, totalUses: Int)] = [:]
        for entry in entries {
            guard let site = QuickSiteSearch.site(fromVisitedURL: entry.url) else { continue }
            let uses = max(entry.visitCount, 1)
            guard var current = best[site.keyword] else {
                best[site.keyword] = (site.host, site.template, uses, uses)
                continue
            }
            if uses > current.templateUses {
                current.host = site.host
                current.template = site.template
                current.templateUses = uses
            }
            current.totalUses += uses
            best[site.keyword] = current
        }

        return best.compactMap { keyword, entry in
            guard entry.totalUses >= minimumUseCount else { return nil }
            return QuickSiteSearchSite(
                keyword: keyword, host: entry.host, template: entry.template, useCount: entry.totalUses
            )
        }
    }
}
