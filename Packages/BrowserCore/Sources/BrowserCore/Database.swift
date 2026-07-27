import Foundation

/// Owns the single `browser.db` SQLite connection for one profile and
/// serializes every access onto a private queue. SQLite is opened with
/// `SQLITE_OPEN_FULLMUTEX`, so the C library itself would also serialize
/// concurrent calls, but funneling everything through one queue here keeps
/// multi-statement operations (e.g. "upsert history_urls, then insert
/// history_visits") atomic with respect to other callers without needing a
/// second lock, and is the behavior the unit tests pin down.
public final class Database {
    private let connection: SQLiteConnection
    private let queue: DispatchQueue

    /// Opens (creating if necessary) `browser.db` inside `profileDirectory`,
    /// creating the directory itself if needed, and brings the schema up to
    /// date.
    public init(profileDirectory: URL) throws {
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let dbPath = profileDirectory.appendingPathComponent("browser.db").path
        self.connection = try SQLiteConnection(path: dbPath)
        self.queue = DispatchQueue(label: "com.browser.BrowserCore.Database")
        try queue.sync {
            try Migrations.run(on: connection)
        }
    }

    /// Runs `body` synchronously on the database's serial queue, giving it
    /// exclusive access to the underlying connection for the duration of the
    /// call. Callers that need several statements to be atomic (e.g. an
    /// upsert followed by a dependent insert) should perform them all inside
    /// one `perform` call, wrapping in `connection.withTransaction` if the
    /// statements must also be atomic with respect to a crash mid-way.
    @discardableResult
    func perform<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync {
            try body(connection)
        }
    }
}
