import Foundation
import SQLite3

/// Thin wrapper over a single prepared `sqlite3_stmt`. Bind indices are
/// 1-based (SQLite's own convention); column indices are 0-based.
final class Statement {
    private let handle: OpaquePointer
    private let db: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        self.db = db
        var stmt: OpaquePointer?
        try SQLiteError.check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), db)
        guard let stmt else {
            throw SQLiteError(code: SQLITE_ERROR, message: "sqlite3_prepare_v2 returned no statement")
        }
        self.handle = stmt
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // The SQLITE_TRANSIENT sentinel tells SQLite to copy the bound bytes
    // immediately, since Swift's transient String/Data buffers aren't
    // guaranteed to outlive the sqlite3_step call.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ value: Int64, at index: Int32) throws {
        try SQLiteError.check(sqlite3_bind_int64(handle, index, value), db)
    }

    func bind(_ value: Double, at index: Int32) throws {
        try SQLiteError.check(sqlite3_bind_double(handle, index, value), db)
    }

    func bind(_ value: String?, at index: Int32) throws {
        guard let value else {
            try SQLiteError.check(sqlite3_bind_null(handle, index), db)
            return
        }
        try SQLiteError.check(sqlite3_bind_text(handle, index, value, -1, Self.SQLITE_TRANSIENT), db)
    }

    func bindNull(at index: Int32) throws {
        try SQLiteError.check(sqlite3_bind_null(handle, index), db)
    }

    /// Steps once. Returns `true` if a row is available (`SQLITE_ROW`),
    /// `false` when the statement is exhausted (`SQLITE_DONE`).
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        try SQLiteError.check(rc, db, okCodes: [SQLITE_ROW, SQLITE_DONE])
        return rc == SQLITE_ROW
    }

    func reset() throws {
        try SQLiteError.check(sqlite3_reset(handle), db)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func text(_ column: Int32) -> String {
        guard let cString = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: cString)
    }

    func dataOrNil(_ column: Int32) -> Data? {
        guard !isNull(column), let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }

    func textOrNil(_ column: Int32) -> String? {
        isNull(column) ? nil : text(column)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }
}
