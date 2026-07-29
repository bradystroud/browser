import Foundation
import SQLite3

/// A single open SQLite connection. Not thread-safe on its own -- callers
/// (see `Database`) are responsible for serializing access.
final class SQLiteConnection {
    private let handle: OpaquePointer

    /// `readOnly` is for opening a file this app doesn't own the schema/
    /// writes for (browser-ymx's Safari-history import reads a copy of
    /// Safari's own History.db this way) -- SQLITE_OPEN_READONLY instead of
    /// the default READWRITE|CREATE, and skips the two PRAGMAs below
    /// entirely: `journal_mode = WAL` fails outright on a read-only-opened
    /// connection (it requires write access to change), and
    /// `foreign_keys = ON` has nothing to enforce on a connection that
    /// never writes.
    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        try SQLiteError.check(sqlite3_open_v2(path, &db, flags, nil), db)
        guard let db else {
            throw SQLiteError(code: SQLITE_ERROR, message: "sqlite3_open_v2 returned no handle")
        }
        self.handle = db
        guard !readOnly else { return }
        try SQLiteError.check(sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil), db)
        try SQLiteError.check(sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil), db)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        try SQLiteError.check(sqlite3_exec(handle, sql, nil, nil, nil), handle)
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(db: handle, sql: sql)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var changes: Int32 {
        sqlite3_changes(handle)
    }

    var userVersion: Int32 {
        get {
            guard let stmt = try? prepare("PRAGMA user_version;") else { return 0 }
            _ = try? stmt.step()
            return Int32(stmt.int(0))
        }
    }

    func setUserVersion(_ version: Int32) throws {
        // PRAGMA doesn't accept bound parameters; the value is an internal
        // Int32 we control, never user input, so string interpolation here
        // is safe.
        try execute("PRAGMA user_version = \(version);")
    }

    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}
