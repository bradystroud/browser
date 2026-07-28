import Foundation

/// The start page's "Favorites" section reads from a special top-level
/// bookmark folder, created lazily the first time anything asks for it --
/// there's no dedicated "add to favorites" UI yet (a ⌘D-equivalent quick-add
/// is a later enhancement per browser-5kq.4); for now, a user adds to it
/// through the ordinary Bookmarks manager, same as any other folder, once
/// it exists.
enum FavoritesFolder {
    static let title = "Favorites"

    /// The folder's id, creating an empty one via `bookmarks` if this
    /// profile has never had one. Returns nil only if BookmarkStore itself
    /// fails (a genuine SQLite/filesystem error) -- callers should treat
    /// that the same as "no favorites yet," not fatal.
    static func id(in bookmarks: BookmarkStore) -> Int64? {
        if let existing = try? bookmarks.children(of: nil).first(where: { $0.kind == .folder && $0.title == title }) {
            return existing.id
        }
        return try? bookmarks.addFolder(title: title, parentId: nil)
    }
}
