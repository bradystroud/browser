import Foundation

/// Writes a parsed `ImportedBookmarkNode` tree into a `BookmarkStore`
/// (browser-ymx). Pure BookmarkStore operations, no AppKit -- the app-side
/// import flow (NSOpenPanel, confirmation sheet) is a thin wrapper around
/// this.
public enum BookmarkImporter {
    /// Imports `nodes` into `bookmarks`, under `destinationParentId` (nil =
    /// top level) -- except any folder flagged `isFavoritesBar`, whose
    /// children are merged directly into `favoritesFolderId` (if provided)
    /// instead of being recreated as a nested folder. This is what maps
    /// Safari's "Favorites"/Chrome's "Bookmarks bar" folder onto this app's
    /// own Favorites folder, so an imported favorite shows up on the start
    /// page's Favorites section. Bookmarks are deduped by exact URL within
    /// whichever folder they land in; folders are not deduped by title (a
    /// second import of the same file creates a second folder, matching
    /// the plain "dedupe by URL" scope this was asked for).
    ///
    /// Returns every bookmark URL actually inserted (not skipped as a
    /// duplicate) -- for the caller to kick lazy favicon fetches against
    /// afterward, without needing to re-walk the tree itself.
    @discardableResult
    public static func importNodes(
        _ nodes: [ImportedBookmarkNode],
        into bookmarks: BookmarkStore,
        destinationParentId: Int64?,
        favoritesFolderId: Int64?
    ) -> [String] {
        var insertedURLs: [String] = []
        for node in nodes {
            switch node {
            case .bookmark(let title, let url):
                if addIfNotDuplicate(title: title, url: url, parentId: destinationParentId, in: bookmarks) {
                    insertedURLs.append(url)
                }

            case .folder(let title, let isFavoritesBar, let children):
                if isFavoritesBar, let favoritesFolderId {
                    insertedURLs += importNodes(children, into: bookmarks, destinationParentId: favoritesFolderId, favoritesFolderId: favoritesFolderId)
                } else {
                    let folderId = (try? bookmarks.addFolder(title: title, parentId: destinationParentId)) ?? destinationParentId
                    insertedURLs += importNodes(children, into: bookmarks, destinationParentId: folderId, favoritesFolderId: favoritesFolderId)
                }
            }
        }
        return insertedURLs
    }

    @discardableResult
    private static func addIfNotDuplicate(title: String, url: String, parentId: Int64?, in bookmarks: BookmarkStore) -> Bool {
        let existing = (try? bookmarks.children(of: parentId)) ?? []
        guard !existing.contains(where: { $0.kind == .bookmark && $0.url == url }) else { return false }
        guard (try? bookmarks.addBookmark(title: title, url: url, parentId: parentId)) != nil else { return false }
        return true
    }
}
