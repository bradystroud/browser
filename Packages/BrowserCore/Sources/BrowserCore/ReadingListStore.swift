import Foundation

extension Notification.Name {
    /// Posted after any ReadingListStore mutation succeeds, `object` being
    /// the store that changed -- same shape as `.bookmarkStoreDidChange`
    /// (see BookmarkStore), so the menu, the list window and the start page
    /// can each refresh without every call site remembering to tell them.
    public static let readingListDidChange = Notification.Name("ReadingListDidChange")
}

/// One saved article. Deliberately does NOT carry the captured HTML: a
/// captured article runs to hundreds of kilobytes, and a reading list of a
/// few hundred items would be tens of megabytes held in memory just to draw
/// a list of titles. `hasArticle` is what a list row needs; the HTML itself
/// comes from `ReadingListStore.article(id:)` when something is actually
/// about to render it.
public struct ReadingListItem: Hashable {
    public let id: Int64
    public let url: String
    public let title: String
    /// Readability's author line, empty when the page had none.
    public let byline: String
    /// A short plain-text summary for the list row, empty until capture.
    public let excerpt: String
    public let addedAt: Date
    public let isRead: Bool
    public let readAt: Date?
    /// Whether an offline copy was captured. False means the item still
    /// needs the network to read -- capture can fail, and a page can be
    /// added from a context where no capture was possible at all.
    public let hasArticle: Bool
}

public enum ReadingListError: Error {
    case itemNotFound
    /// The captured article was larger than `maximumArticleBytes`.
    case articleTooLarge
}

/// Per-profile reading list: a page saved to read later, with an offline
/// copy of the article and unread state (browser-56p).
///
/// **Adding and capturing are two separate steps, on purpose.** Capture
/// means running Readability inside the page and waiting for the answer to
/// come back through the page-message channel, which takes as long as it
/// takes and can fail outright. `add` therefore records the item
/// immediately, so the UI can respond to ⇧⌘D in the same run loop turn, and
/// `saveArticle` fills in the offline copy whenever it arrives. An item
/// with `hasArticle == false` is a normal, expected state -- not a failure
/// to paper over.
public final class ReadingListStore {
    /// A captured article larger than this is refused rather than stored.
    ///
    /// The ceiling is not about database size -- it is about being able to
    /// render the article back. An offline article is displayed as a
    /// base64 `data:` URL (the same vehicle the start page uses), and
    /// Chromium refuses any URL over `url::kMaxURLChars`, 2 MiB. base64
    /// costs about 1.34x, so the document has to stay under roughly 1.57 MB
    /// for the URL to be accepted at all -- and a page over the limit does
    /// not fail loudly, it renders as a blank window (confirmed live for
    /// the start page's background image, see
    /// StartPageBackgroundImageStore.maxEncodedBytes). One megabyte keeps
    /// about a third in reserve for the template around the article.
    ///
    /// Readability output is text and inline markup, so a real article --
    /// even a very long one -- lands far below this. Something above it is
    /// a page that defeated the extractor, and storing that would cost the
    /// profile database a megabyte for nothing readable.
    public static let maximumArticleBytes = 1024 * 1024

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Adding

    /// Adds `url`, or updates the row already there. Returns the item's id
    /// either way, so a caller can hand it straight to `saveArticle`.
    ///
    /// Re-adding a page already on the list is not an error and never
    /// duplicates it. What it does depends on whether that item was read:
    /// an unread item only picks up a fresher title (its place in the list
    /// is where the user put it), while a read item is marked unread again
    /// and moved to the top -- the only reason to save something you have
    /// already read is to read it again.
    @discardableResult
    public func add(url: String, title: String, at date: Date = Date()) throws -> Int64 {
        let id = try database.perform { db in
            try db.withTransaction {
                let existing = try db.prepare("SELECT id, is_read FROM reading_list_items WHERE url = ?;")
                try existing.bind(url, at: 1)
                if try existing.step() {
                    let id = existing.int64(0)
                    let wasRead = existing.int(1) != 0
                    let update = try db.prepare("""
                        UPDATE reading_list_items
                        SET title = CASE WHEN ? = '' THEN title ELSE ? END,
                            is_read = 0,
                            read_at = NULL,
                            added_at = CASE WHEN ? = 1 THEN ? ELSE added_at END
                        WHERE id = ?;
                        """)
                    try update.bind(title, at: 1)
                    try update.bind(title, at: 2)
                    try update.bind(Int64(wasRead ? 1 : 0), at: 3)
                    try update.bind(Self.milliseconds(date), at: 4)
                    try update.bind(id, at: 5)
                    try update.step()
                    return id
                }

                let insert = try db.prepare("""
                    INSERT INTO reading_list_items (url, title, byline, excerpt, article_html, added_at, is_read, read_at)
                    VALUES (?, ?, '', '', NULL, ?, 0, NULL);
                    """)
                try insert.bind(url, at: 1)
                try insert.bind(title, at: 2)
                try insert.bind(Self.milliseconds(date), at: 3)
                try insert.step()
                return db.lastInsertRowID
            }
        }
        postDidChange()
        return id
    }

    /// Stores the offline copy for an item. `content` is Readability's
    /// extracted article markup -- the same string Reader mode renders --
    /// and is stored exactly as given: escaping or sanitizing it here would
    /// corrupt the markup, so the guarantee that it cannot execute anything
    /// belongs to whatever renders it (see ReadingListArticleTemplate,
    /// which serves it under a script-blocking Content-Security-Policy).
    public func saveArticle(id: Int64, content: String, byline: String = "", excerpt: String = "") throws {
        guard content.utf8.count <= Self.maximumArticleBytes else { throw ReadingListError.articleTooLarge }
        try database.perform { db in
            let stmt = try db.prepare("""
                UPDATE reading_list_items SET article_html = ?, byline = ?, excerpt = ? WHERE id = ?;
                """)
            try stmt.bind(content, at: 1)
            try stmt.bind(byline, at: 2)
            try stmt.bind(excerpt, at: 3)
            try stmt.bind(id, at: 4)
            try stmt.step()
            guard db.changes > 0 else { throw ReadingListError.itemNotFound }
        }
        postDidChange()
    }

    // MARK: - Reading

    /// Newest first, which is the order a reading list is worked through.
    public func items(unreadOnly: Bool = false, limit: Int = 500) throws -> [ReadingListItem] {
        try database.perform { db in
            let stmt = try db.prepare("""
                SELECT id, url, title, byline, excerpt, added_at, is_read, read_at, article_html IS NOT NULL
                FROM reading_list_items
                WHERE (? = 0 OR is_read = 0)
                ORDER BY added_at DESC
                LIMIT ?;
                """)
            try stmt.bind(Int64(unreadOnly ? 1 : 0), at: 1)
            try stmt.bind(Int64(limit), at: 2)
            var results: [ReadingListItem] = []
            while try stmt.step() {
                results.append(Self.item(from: stmt))
            }
            return results
        }
    }

    public func item(url: String) throws -> ReadingListItem? {
        try database.perform { db in
            let stmt = try db.prepare("""
                SELECT id, url, title, byline, excerpt, added_at, is_read, read_at, article_html IS NOT NULL
                FROM reading_list_items WHERE url = ?;
                """)
            try stmt.bind(url, at: 1)
            return try stmt.step() ? Self.item(from: stmt) : nil
        }
    }

    public func contains(url: String) throws -> Bool {
        try item(url: url) != nil
    }

    /// The offline copy, or nil when there isn't one. Kept off
    /// `ReadingListItem` deliberately -- see that type's doc comment.
    public func article(id: Int64) throws -> String? {
        try database.perform { db in
            let stmt = try db.prepare("SELECT article_html FROM reading_list_items WHERE id = ?;")
            try stmt.bind(id, at: 1)
            guard try stmt.step() else { return nil }
            return stmt.textOrNil(0)
        }
    }

    public func unreadCount() throws -> Int {
        try database.perform { db in
            let stmt = try db.prepare("SELECT COUNT(*) FROM reading_list_items WHERE is_read = 0;")
            return try stmt.step() ? stmt.int(0) : 0
        }
    }

    // MARK: - Mutating

    public func markRead(id: Int64, _ isRead: Bool = true, at date: Date = Date()) throws {
        try database.perform { db in
            let stmt = try db.prepare("UPDATE reading_list_items SET is_read = ?, read_at = ? WHERE id = ?;")
            try stmt.bind(Int64(isRead ? 1 : 0), at: 1)
            if isRead { try stmt.bind(Self.milliseconds(date), at: 2) } else { try stmt.bindNull(at: 2) }
            try stmt.bind(id, at: 3)
            try stmt.step()
            guard db.changes > 0 else { throw ReadingListError.itemNotFound }
        }
        postDidChange()
    }

    public func remove(id: Int64) throws {
        try database.perform { db in
            let stmt = try db.prepare("DELETE FROM reading_list_items WHERE id = ?;")
            try stmt.bind(id, at: 1)
            try stmt.step()
            guard db.changes > 0 else { throw ReadingListError.itemNotFound }
        }
        postDidChange()
    }

    /// Removes every item that has been read, which is the "tidy up" action
    /// a reading list needs and the only bulk delete worth offering: a list
    /// of unread articles is the thing the user is keeping.
    @discardableResult
    public func removeRead() throws -> Int {
        let removed = try database.perform { db in
            try db.execute("DELETE FROM reading_list_items WHERE is_read = 1;")
            return Int(db.changes)
        }
        if removed > 0 { postDidChange() }
        return removed
    }

    public func removeAll() throws {
        try database.perform { db in
            try db.execute("DELETE FROM reading_list_items;")
        }
        postDidChange()
    }

    // MARK: - Internals

    private static func item(from stmt: Statement) -> ReadingListItem {
        ReadingListItem(
            id: stmt.int64(0),
            url: stmt.text(1),
            title: stmt.text(2),
            byline: stmt.text(3),
            excerpt: stmt.text(4),
            addedAt: date(fromMilliseconds: stmt.int64(5)),
            isRead: stmt.int(6) != 0,
            readAt: stmt.isNull(7) ? nil : date(fromMilliseconds: stmt.int64(7)),
            hasArticle: stmt.int(8) != 0
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func date(fromMilliseconds value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1000)
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: .readingListDidChange, object: self)
    }
}
