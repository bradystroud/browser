import Foundation

public enum DownloadState: String {
    case pending
    case inProgress
    case completed
    case cancelled
    case failed
    case interrupted
}

public struct DownloadItem: Equatable {
    public let id: Int64
    public let url: String
    public let suggestedName: String
    public let destinationPath: String
    public let state: DownloadState
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public let startedAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
}

public final class DownloadStore {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    @discardableResult
    public func create(url: String, suggestedName: String, destinationPath: String, at date: Date = Date()) throws -> Int64 {
        let epochMs = Self.epochMs(date)
        return try database.perform { db in
            let stmt = try db.prepare("""
                INSERT INTO downloads (url, suggested_name, destination_path, state, received_bytes, total_bytes, started_at, updated_at)
                VALUES (?, ?, ?, ?, 0, -1, ?, ?);
                """)
            try stmt.bind(url, at: 1)
            try stmt.bind(suggestedName, at: 2)
            try stmt.bind(destinationPath, at: 3)
            try stmt.bind(DownloadState.pending.rawValue, at: 4)
            try stmt.bind(epochMs, at: 5)
            try stmt.bind(epochMs, at: 6)
            try stmt.step()
            return db.lastInsertRowID
        }
    }

    public func updateProgress(id: Int64, receivedBytes: Int64, totalBytes: Int64, at date: Date = Date()) throws {
        try database.perform { db in
            let stmt = try db.prepare("""
                UPDATE downloads
                SET state = ?, received_bytes = ?, total_bytes = ?, updated_at = ?
                WHERE id = ?;
                """)
            try stmt.bind(DownloadState.inProgress.rawValue, at: 1)
            try stmt.bind(receivedBytes, at: 2)
            try stmt.bind(totalBytes, at: 3)
            try stmt.bind(Self.epochMs(date), at: 4)
            try stmt.bind(id, at: 5)
            try stmt.step()
        }
    }

    public func updateState(id: Int64, state: DownloadState, at date: Date = Date()) throws {
        let epochMs = Self.epochMs(date)
        try database.perform { db in
            let stmt = try db.prepare("""
                UPDATE downloads
                SET state = ?, updated_at = ?, completed_at = CASE WHEN ? = 'completed' THEN ? ELSE completed_at END
                WHERE id = ?;
                """)
            try stmt.bind(state.rawValue, at: 1)
            try stmt.bind(epochMs, at: 2)
            try stmt.bind(state.rawValue, at: 3)
            try stmt.bind(epochMs, at: 4)
            try stmt.bind(id, at: 5)
            try stmt.step()
        }
    }

    /// Rewinds an existing row to the start of a fresh attempt at the same
    /// download: progress back to zero, state back to `pending`, and the
    /// destination path replaced (a retry resolves its own unique filename,
    /// which need not be the one the first attempt picked).
    ///
    /// This exists because a retry is not a new download. Chromium restarts an
    /// interrupted transfer through the same download item and reports it as
    /// the same id, so the alternative -- inserting a second row -- leaves the
    /// first one stranded in a non-terminal state with no way to ever finish
    /// it (browser-s24: one failed download produced six rows, five of them
    /// permanently "downloading"). `started_at` deliberately survives: the
    /// download started when the user asked for it, not when the engine gave
    /// up and tried again.
    public func restart(id: Int64, destinationPath: String, at date: Date = Date()) throws {
        try database.perform { db in
            let stmt = try db.prepare("""
                UPDATE downloads
                SET state = ?, received_bytes = 0, total_bytes = -1,
                    destination_path = ?, updated_at = ?, completed_at = NULL
                WHERE id = ?;
                """)
            try stmt.bind(DownloadState.pending.rawValue, at: 1)
            try stmt.bind(destinationPath, at: 2)
            try stmt.bind(Self.epochMs(date), at: 3)
            try stmt.bind(id, at: 4)
            try stmt.step()
        }
    }

    /// Marks every row still in a non-terminal state as `interrupted`,
    /// returning how many were changed.
    ///
    /// Call once per database connection, at startup, before any new download
    /// can be recorded. A `pending`/`inProgress` row that is already on disk
    /// when the process starts belongs to a transfer no longer running --
    /// nothing can ever move it to a terminal state, so left alone it shows as
    /// downloading forever (browser-s24). Received bytes are left as they are:
    /// they still describe what actually landed on disk.
    @discardableResult
    public func reconcileUnfinished(at date: Date = Date()) throws -> Int {
        try database.perform { db in
            let stmt = try db.prepare("""
                UPDATE downloads
                SET state = ?, updated_at = ?
                WHERE state IN ('pending', 'inProgress');
                """)
            try stmt.bind(DownloadState.interrupted.rawValue, at: 1)
            try stmt.bind(Self.epochMs(date), at: 2)
            try stmt.step()
            return Int(db.changes)
        }
    }

    public func item(id: Int64) throws -> DownloadItem? {
        try database.perform { db in
            let stmt = try db.prepare("""
                SELECT id, url, suggested_name, destination_path, state, received_bytes, total_bytes, started_at, updated_at, completed_at
                FROM downloads WHERE id = ?;
                """)
            try stmt.bind(id, at: 1)
            guard try stmt.step() else { return nil }
            return Self.item(from: stmt)
        }
    }

    public func all(limit: Int = 200) throws -> [DownloadItem] {
        try database.perform { db in
            let stmt = try db.prepare("""
                SELECT id, url, suggested_name, destination_path, state, received_bytes, total_bytes, started_at, updated_at, completed_at
                FROM downloads
                ORDER BY started_at DESC
                LIMIT ?;
                """)
            try stmt.bind(Int64(limit), at: 1)
            var results: [DownloadItem] = []
            while try stmt.step() {
                results.append(Self.item(from: stmt))
            }
            return results
        }
    }

    public func delete(id: Int64) throws {
        try database.perform { db in
            let stmt = try db.prepare("DELETE FROM downloads WHERE id = ?;")
            try stmt.bind(id, at: 1)
            try stmt.step()
        }
    }

    public func clearCompleted() throws {
        try database.perform { db in
            try db.execute("DELETE FROM downloads WHERE state = 'completed';")
        }
    }

    private static func item(from stmt: Statement) -> DownloadItem {
        DownloadItem(
            id: stmt.int64(0),
            url: stmt.text(1),
            suggestedName: stmt.text(2),
            destinationPath: stmt.text(3),
            state: DownloadState(rawValue: stmt.text(4)) ?? .pending,
            receivedBytes: stmt.int64(5),
            totalBytes: stmt.int64(6),
            startedAt: Date(timeIntervalSince1970: Double(stmt.int64(7)) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(stmt.int64(8)) / 1000),
            completedAt: stmt.isNull(9) ? nil : Date(timeIntervalSince1970: Double(stmt.int64(9)) / 1000)
        )
    }

    private static func epochMs(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
