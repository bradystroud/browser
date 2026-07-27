import Foundation

public enum BookmarkKind: String, Hashable {
    case folder
    case bookmark
}

/// Hashable (not just Equatable) so a value can be used directly as an
/// NSOutlineView item -- the Bookmarks manager window's expand/collapse
/// state tracking needs stable hashing, not just equality.
public struct BookmarkItem: Hashable {
    public let id: Int64
    public let parentId: Int64?
    public let kind: BookmarkKind
    public let title: String
    public let url: String?
    public let position: Int
    public let createdAt: Date
}

public enum BookmarkError: Error {
    case itemNotFound
}

/// Bookmarks and folders share one table (`bookmark_items`) ordered by a
/// single `position` sequence per parent, so folders and bookmarks interleave
/// in listing order the same way a real bookmarks bar does -- there's no
/// separate ordering axis for "folders first."
public final class BookmarkStore {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    @discardableResult
    public func addFolder(title: String, parentId: Int64?, at date: Date = Date()) throws -> Int64 {
        try insert(kind: .folder, title: title, url: nil, parentId: parentId, at: date)
    }

    @discardableResult
    public func addBookmark(title: String, url: String, parentId: Int64?, at date: Date = Date()) throws -> Int64 {
        try insert(kind: .bookmark, title: title, url: url, parentId: parentId, at: date)
    }

    private func insert(kind: BookmarkKind, title: String, url: String?, parentId: Int64?, at date: Date) throws -> Int64 {
        try database.perform { db in
            try db.withTransaction {
                let count = try Self.childCount(parentId: parentId, db: db)
                let insert = try db.prepare("""
                    INSERT INTO bookmark_items (parent_id, kind, title, url, position, created_at)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """)
                if let parentId { try insert.bind(parentId, at: 1) } else { try insert.bindNull(at: 1) }
                try insert.bind(kind.rawValue, at: 2)
                try insert.bind(title, at: 3)
                try insert.bind(url, at: 4)
                try insert.bind(Int64(count), at: 5)
                try insert.bind(Int64(date.timeIntervalSince1970 * 1000), at: 6)
                try insert.step()
                return db.lastInsertRowID
            }
        }
    }

    /// Children of `parentId` (nil = top level), ordered by position.
    public func children(of parentId: Int64?) throws -> [BookmarkItem] {
        try database.perform { db in
            let stmt = try db.prepare("""
                SELECT id, parent_id, kind, title, url, position, created_at
                FROM bookmark_items
                WHERE parent_id IS ?
                ORDER BY position ASC;
                """)
            if let parentId { try stmt.bind(parentId, at: 1) } else { try stmt.bindNull(at: 1) }
            var results: [BookmarkItem] = []
            while try stmt.step() {
                results.append(Self.item(from: stmt))
            }
            return results
        }
    }

    public func item(id: Int64) throws -> BookmarkItem? {
        try database.perform { db in
            let stmt = try db.prepare("""
                SELECT id, parent_id, kind, title, url, position, created_at
                FROM bookmark_items WHERE id = ?;
                """)
            try stmt.bind(id, at: 1)
            guard try stmt.step() else { return nil }
            return Self.item(from: stmt)
        }
    }

    public func rename(itemId: Int64, title: String) throws {
        try database.perform { db in
            let stmt = try db.prepare("UPDATE bookmark_items SET title = ? WHERE id = ?;")
            try stmt.bind(title, at: 1)
            try stmt.bind(itemId, at: 2)
            try stmt.step()
        }
    }

    public func updateURL(itemId: Int64, url: String) throws {
        try database.perform { db in
            let stmt = try db.prepare("UPDATE bookmark_items SET url = ? WHERE id = ?;")
            try stmt.bind(url, at: 1)
            try stmt.bind(itemId, at: 2)
            try stmt.step()
        }
    }

    /// Moves `itemId` to be a child of `toParentId` at position `index`
    /// (clamped to the destination's bounds), renumbering both the source
    /// and destination sibling lists so every position stays a dense,
    /// gap-free sequence.
    public func move(itemId: Int64, toParentId: Int64?, index: Int) throws {
        try database.perform { db in
            try db.withTransaction {
                let select = try db.prepare("SELECT parent_id FROM bookmark_items WHERE id = ?;")
                try select.bind(itemId, at: 1)
                guard try select.step() else { throw BookmarkError.itemNotFound }
                let oldParentId: Int64? = select.isNull(0) ? nil : select.int64(0)

                let reparent = try db.prepare("UPDATE bookmark_items SET parent_id = ? WHERE id = ?;")
                if let toParentId { try reparent.bind(toParentId, at: 1) } else { try reparent.bindNull(at: 1) }
                try reparent.bind(itemId, at: 2)
                try reparent.step()

                if oldParentId != toParentId {
                    try Self.renumber(parentId: oldParentId, db: db)
                }

                var siblingIds = try Self.childIds(parentId: toParentId, db: db, excluding: itemId)
                let clampedIndex = max(0, min(index, siblingIds.count))
                siblingIds.insert(itemId, at: clampedIndex)
                try Self.applyPositions(siblingIds, db: db)
            }
        }
    }

    public func delete(itemId: Int64) throws {
        try database.perform { db in
            try db.withTransaction {
                let select = try db.prepare("SELECT parent_id FROM bookmark_items WHERE id = ?;")
                try select.bind(itemId, at: 1)
                let parentId: Int64? = try select.step() ? (select.isNull(0) ? nil : select.int64(0)) : nil

                let delete = try db.prepare("DELETE FROM bookmark_items WHERE id = ?;")
                try delete.bind(itemId, at: 1)
                try delete.step()

                try Self.renumber(parentId: parentId, db: db)
            }
        }
    }

    private static func item(from stmt: Statement) -> BookmarkItem {
        BookmarkItem(
            id: stmt.int64(0),
            parentId: stmt.isNull(1) ? nil : stmt.int64(1),
            kind: BookmarkKind(rawValue: stmt.text(2)) ?? .bookmark,
            title: stmt.text(3),
            url: stmt.textOrNil(4),
            position: stmt.int(5),
            createdAt: Date(timeIntervalSince1970: Double(stmt.int64(6)) / 1000)
        )
    }

    private static func childCount(parentId: Int64?, db: SQLiteConnection) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM bookmark_items WHERE parent_id IS ?;")
        if let parentId { try stmt.bind(parentId, at: 1) } else { try stmt.bindNull(at: 1) }
        _ = try stmt.step()
        return stmt.int(0)
    }

    private static func childIds(parentId: Int64?, db: SQLiteConnection, excluding: Int64? = nil) throws -> [Int64] {
        let stmt = try db.prepare("""
            SELECT id FROM bookmark_items WHERE parent_id IS ? ORDER BY position ASC;
            """)
        if let parentId { try stmt.bind(parentId, at: 1) } else { try stmt.bindNull(at: 1) }
        var ids: [Int64] = []
        while try stmt.step() {
            let id = stmt.int64(0)
            if id != excluding {
                ids.append(id)
            }
        }
        return ids
    }

    private static func renumber(parentId: Int64?, db: SQLiteConnection) throws {
        let ids = try childIds(parentId: parentId, db: db)
        try applyPositions(ids, db: db)
    }

    private static func applyPositions(_ ids: [Int64], db: SQLiteConnection) throws {
        let stmt = try db.prepare("UPDATE bookmark_items SET position = ? WHERE id = ?;")
        for (index, id) in ids.enumerated() {
            try stmt.reset()
            try stmt.bind(Int64(index), at: 1)
            try stmt.bind(id, at: 2)
            try stmt.step()
        }
    }
}
