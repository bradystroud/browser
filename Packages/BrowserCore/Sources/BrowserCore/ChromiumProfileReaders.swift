import Foundation

/// Reads a Chromium-family browser profile's own files: `Login Data`,
/// `History` (both SQLite) and `Bookmarks` (JSON).
///
/// The SQLite files are always read from a private copy
/// (`withCopiedDatabase`): the browser that owns them is usually running and
/// holding locks, and it must never see this app open its live files. The
/// copy includes any `-wal` sidecar, which is where a running browser's most
/// recent writes (a password saved a minute ago) still sit, and the copy is
/// opened read-write so SQLite can fold that log in -- a read-only open of a
/// WAL-mode copy fails outright.

public struct ChromiumLoginRow: Equatable {
    public let originURL: String
    public let username: String
    public let encryptedPassword: Data
    /// `blacklisted_by_user`: the user told the browser never to save a
    /// password for this site.
    public let isNeverSave: Bool

    public init(originURL: String, username: String, encryptedPassword: Data, isNeverSave: Bool) {
        self.originURL = originURL
        self.username = username
        self.encryptedPassword = encryptedPassword
        self.isNeverSave = isNeverSave
    }
}

public struct ChromiumHistoryVisit: Equatable {
    public let url: String
    public let title: String?
    public let visitTime: Date
}

public enum ChromiumProfileReader {
    public enum ReadError: Error {
        case fileNotReadable
        case unexpectedFormat
    }

    /// Copies `source` into a fresh owner-only temporary directory, runs
    /// `body` against the copy's path, and deletes the directory afterwards
    /// whether or not `body` throws.
    ///
    /// The `-wal` is copied before the database: if the owner checkpoints
    /// between the two copies, an older log over a newer database replays
    /// pages the database already has, whereas the reverse order pairs an
    /// old database with a log that no longer describes it. A checkpoint can
    /// still land mid-copy, so a copy that fails to read is taken once more.
    public static func withCopiedDatabase<T>(at source: URL, _ body: (String) throws -> T) throws -> T {
        do {
            return try withSingleCopy(of: source, body)
        } catch ReadError.fileNotReadable {
            throw ReadError.fileNotReadable
        } catch {
            return try withSingleCopy(of: source, body)
        }
    }

    private static func withSingleCopy<T>(of source: URL, _ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromium-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            try? FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            throw ReadError.fileNotReadable
        }
        return try body(copy.path)
    }

    public static func readLogins(fromCopiedDatabaseAt path: String) throws -> [ChromiumLoginRow] {
        let connection: SQLiteConnection
        let statement: Statement
        do {
            connection = try SQLiteConnection(path: path)
            statement = try connection.prepare("""
                SELECT origin_url, username_value, password_value, blacklisted_by_user FROM logins;
                """)
        } catch {
            throw ReadError.unexpectedFormat
        }
        var rows: [ChromiumLoginRow] = []
        while try statement.step() {
            rows.append(ChromiumLoginRow(
                originURL: statement.text(0),
                username: statement.text(1),
                encryptedPassword: statement.blob(2),
                isNeverSave: statement.int(3) != 0
            ))
        }
        withExtendedLifetime(connection) {}
        return rows
    }

    /// Chromium stores times as microseconds since 1601-01-01 UTC.
    static func date(fromChromiumTime microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    /// Most recent visits first, http(s) only, at most `limit`.
    public static func readVisits(fromCopiedDatabaseAt path: String, limit: Int = 100_000) throws -> [ChromiumHistoryVisit] {
        let connection: SQLiteConnection
        let statement: Statement
        do {
            connection = try SQLiteConnection(path: path)
            statement = try connection.prepare("""
                SELECT urls.url, urls.title, visits.visit_time
                FROM visits JOIN urls ON visits.url = urls.id
                WHERE urls.hidden = 0 AND (urls.url LIKE 'http://%' OR urls.url LIKE 'https://%')
                ORDER BY visits.visit_time DESC
                LIMIT ?;
                """)
            try statement.bind(Int64(limit), at: 1)
        } catch {
            throw ReadError.unexpectedFormat
        }
        var visits: [ChromiumHistoryVisit] = []
        while try statement.step() {
            let url = statement.text(0)
            let title = statement.textOrNil(1).flatMap { $0.isEmpty ? nil : $0 }
            visits.append(ChromiumHistoryVisit(url: url, title: title, visitTime: date(fromChromiumTime: statement.int64(2))))
        }
        withExtendedLifetime(connection) {}
        return visits
    }

    /// The bookmarks bar becomes the favourites-bar folder; "Other" and
    /// "Mobile" become ordinary top-level folders when they hold anything.
    /// Non-web URLs (javascript:, chrome://, file:) are dropped, and folders
    /// left empty by that are dropped too.
    public static func parseBookmarks(data: Data) throws -> [ImportedBookmarkNode] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = top["roots"] as? [String: Any]
        else { throw ReadError.unexpectedFormat }

        var nodes: [ImportedBookmarkNode] = []
        if let bar = roots["bookmark_bar"] as? [String: Any] {
            let children = bookmarkNodes(bar["children"] as? [[String: Any]] ?? [])
            if !children.isEmpty {
                nodes.append(.folder(title: nonEmpty(bar["name"]) ?? "Bookmarks Bar", isFavoritesBar: true, children: children))
            }
        }
        for (key, fallback) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            guard let root = roots[key] as? [String: Any] else { continue }
            let children = bookmarkNodes(root["children"] as? [[String: Any]] ?? [])
            if !children.isEmpty {
                nodes.append(.folder(title: nonEmpty(root["name"]) ?? fallback, isFavoritesBar: false, children: children))
            }
        }
        return nodes
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func bookmarkNodes(_ raw: [[String: Any]]) -> [ImportedBookmarkNode] {
        raw.compactMap { entry in
            switch entry["type"] as? String {
            case "folder":
                let children = bookmarkNodes(entry["children"] as? [[String: Any]] ?? [])
                guard !children.isEmpty else { return nil }
                return .folder(title: nonEmpty(entry["name"]) ?? "Untitled", isFavoritesBar: false, children: children)
            case "url":
                guard let url = entry["url"] as? String,
                      url.hasPrefix("http://") || url.hasPrefix("https://")
                else { return nil }
                return .bookmark(title: nonEmpty(entry["name"]) ?? url, url: url)
            default:
                return nil
            }
        }
    }
}
