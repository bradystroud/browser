import Foundation

/// One tile in a start-page section -- a Favourites bookmark or a history
/// entry, reduced to the two things every presentation of it needs.
struct StartPageTile: Equatable {
    let title: String
    let url: String
}

/// A titled group of tiles, plus the message to show in place of the grid
/// when it has none. The empty message is part of the section rather than the
/// renderer's business because both presentations must say the same thing
/// (browser-5kq.7's rule: an empty section stays visible and actionable
/// instead of disappearing).
struct StartPageSection: Equatable {
    /// What the section holds, so a presentation can give the two kinds
    /// different shapes without matching on `title` -- the HTML start page
    /// draws bookmarks as an icon grid and history as a compact row list.
    /// The omnibox panel ignores this and draws both the same way.
    enum Kind: Equatable {
        case bookmarks
        case history
    }

    let title: String
    let kind: Kind
    let tiles: [StartPageTile]
    let emptyMessage: String
}

/// The single place the start page's content is assembled from a profile's
/// BookmarkStore/HistoryStore, kept apart from the HTML that StartPageRenderer
/// builds from it so any other presentation can share the data path.
enum StartPageSections {
    static let favoritesTitle = "Favorites"
    static let favoritesEmptyMessage = "No favourites yet — press ⌘D on any page to add one."

    /// Which HistoryStore query the second section is built from. The start
    /// page has always shown frecency-ranked "Frequently Visited"; the
    /// omnibox panel shows plain newest-first "Recently Visited" because
    /// that's what Brady asked for ("all your favourites and then recently
    /// underneath that"). Both are gated by the same
    /// StartPageSettings.showFrequentlyVisited toggle -- there is one
    /// user-facing "show me history on the start page" preference, and a
    /// second toggle that only the panel obeyed would be a surprise.
    enum HistoryKind {
        case frequentlyVisited
        case recentlyVisited

        var title: String {
            switch self {
            case .frequentlyVisited: return "Frequently Visited"
            case .recentlyVisited: return "Recently Visited"
            }
        }

        var emptyMessage: String {
            switch self {
            case .frequentlyVisited:
                return "Nothing here yet — browse a bit and your most-visited pages will show up."
            case .recentlyVisited:
                return "Nothing here yet — pages you visit will show up here."
            }
        }
    }

    /// Builds the sections a profile's start page / omnibox panel should
    /// show, honouring that profile's own StartPageSettings toggles. Returns
    /// an empty array only when both toggles are off -- an *enabled* section
    /// with no content is still returned (with empty `tiles`), so callers can
    /// render its empty message.
    static func build(
        profileId: String,
        settings: StartPageSettings,
        historyKind: HistoryKind,
        limit: Int = 8
    ) -> [StartPageSection] {
        guard let profile = ProfileManager.shared.profile(id: profileId) else { return [] }
        let stores = ProfileDataStoreManager.shared.stores(for: profile)

        var sections: [StartPageSection] = []

        if settings.showFavorites {
            var tiles: [StartPageTile] = []
            if let folderId = FavoritesFolder.id(in: stores.bookmarks) {
                let items = (try? stores.bookmarks.children(of: folderId)) ?? []
                tiles = items.compactMap { item in
                    guard item.kind == .bookmark, let url = item.url else { return nil }
                    return StartPageTile(title: item.title.isEmpty ? url : item.title, url: url)
                }
            }
            sections.append(StartPageSection(
                title: favoritesTitle, kind: .bookmarks, tiles: tiles,
                emptyMessage: favoritesEmptyMessage
            ))
        }

        if settings.showFrequentlyVisited {
            let entries: [HistoryEntry]
            switch historyKind {
            case .frequentlyVisited:
                entries = (try? stores.history.topFrecent(limit: limit)) ?? []
            case .recentlyVisited:
                entries = (try? stores.history.entries(limit: limit)) ?? []
            }
            let tiles = entries
                .filter { isPresentable($0.url) }
                .map { StartPageTile(title: $0.title.isEmpty ? $0.url : $0.title, url: $0.url) }
            sections.append(StartPageSection(
                title: historyKind.title, kind: .history, tiles: tiles,
                emptyMessage: historyKind.emptyMessage
            ))
        }

        return sections
    }

    /// Internal/synthetic URLs are never worth offering as a tile: the start
    /// page itself is a giant base64 `data:` URL (see StartPageRenderer), and
    /// a history row for one would render as an unreadable tile that
    /// navigates nowhere useful.
    private static func isPresentable(_ url: String) -> Bool {
        let lowered = url.lowercased()
        for prefix in ["data:", "about:", "chrome:", "devtools:", "javascript:"] where lowered.hasPrefix(prefix) {
            return false
        }
        return !url.isEmpty
    }
}
