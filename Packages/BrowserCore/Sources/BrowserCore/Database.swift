import Foundation

/// Owns one profile's SQLite connection for one database file and
/// serializes every access onto a private queue. SQLite is opened with
/// `SQLITE_OPEN_FULLMUTEX`, so the C library itself would also serialize
/// concurrent calls, but funneling everything through one queue here keeps
/// multi-statement operations (e.g. "upsert history_urls, then insert
/// history_visits") atomic with respect to other callers without needing a
/// second lock, and is the behavior the unit tests pin down.
///
/// Almost always `browser.db` -- history, bookmarks, downloads and the
/// reading list all share that one file, and share its migration history.
/// The second file is the privacy report (browser-e7r), which is separate
/// on purpose: it is high-write, disposable, 30-day data, so keeping it out
/// of the file holding the durable stuff means it can never bloat or
/// corrupt any of it, and clearing it is deleting one file.
public final class Database {
    private let connection: SQLiteConnection
    private let queue: DispatchQueue

    /// Opens (creating if necessary) `browser.db` inside `profileDirectory`,
    /// creating the directory itself if needed, and brings the schema up to
    /// date.
    public convenience init(profileDirectory: URL) throws {
        try self.init(
            profileDirectory: profileDirectory,
            fileName: "browser.db",
            queueLabel: "com.browser.BrowserCore.Database",
            prepareSchema: Migrations.run(on:)
        )
    }

    /// Opens (creating if necessary) `fileName` inside `profileDirectory`,
    /// creating the directory itself if needed, then hands the fresh
    /// connection to `prepareSchema` to bring it up to date -- the ordered
    /// `Migrations` list for `browser.db`, or a store's own scheme for a
    /// database with different durability needs.
    ///
    /// `queueLabel` is per-file rather than shared: two databases have no
    /// reason to serialize against each other, and a report flush should
    /// never be able to sit behind a history query.
    init(
        profileDirectory: URL,
        fileName: String,
        queueLabel: String,
        prepareSchema: (SQLiteConnection) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let dbPath = profileDirectory.appendingPathComponent(fileName).path
        self.connection = try SQLiteConnection(path: dbPath)
        self.queue = DispatchQueue(label: queueLabel)
        try queue.sync {
            try prepareSchema(connection)
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
