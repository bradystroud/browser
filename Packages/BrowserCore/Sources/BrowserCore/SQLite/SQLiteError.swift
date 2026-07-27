import SQLite3

/// Wraps a non-OK SQLite result code together with the connection's last
/// error message, which SQLite only exposes via `sqlite3_errmsg` at the
/// point of failure (it's not derivable from the code alone).
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String {
        "SQLiteError(code: \(code), message: \(message))"
    }

    static func check(_ code: Int32, _ db: OpaquePointer?, okCodes: Set<Int32> = [SQLITE_OK]) throws {
        guard !okCodes.contains(code) else { return }
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        throw SQLiteError(code: code, message: message)
    }
}
