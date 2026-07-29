import Foundation

/// One row from Safari's `history_visits` table, joined back to its URL.
public struct SafariHistoryVisit: Equatable {
    public let url: String
    public let title: String?
    public let visitTime: Date

    public init(url: String, title: String?, visitTime: Date) {
        self.url = url
        self.title = title
        self.visitTime = visitTime
    }
}

/// Reads Safari's `History.db` (the full Safari import, browser-ymx) --
/// WebKit's long-standing schema: `history_items` (one row per distinct
/// URL) joined to `history_visits` (one row per individual visit event)
/// via `history_visits.history_item`. `visit_time` is Mac absolute time
/// (seconds since 2001-01-01 00:00:00 UTC) -- exactly Foundation's own
/// `timeIntervalSinceReferenceDate` epoch, so no manual offset arithmetic
/// is needed to convert it to a `Date`. See docs/ai-tasks/
/// safari-import-notes.md for the citations behind this schema and why
/// it's "reasonably confident, not independently verified on a live Mac"
/// (this machine's own ~/Library/Safari is itself TCC-protected even for
/// a plain directory listing, the same protection this whole feature is
/// designed around).
///
/// Never opens Safari's live database directly -- always operates on a
/// caller-supplied path, which the caller must have already copied out of
/// Safari's own directory first (Safari holds locks on its live files,
/// and may have pending writes sitting in a `-wal` sidecar file a plain
/// file copy of just the main `.db` won't include -- meaning the very
/// latest, not-yet-checkpointed visits can be missed; an accepted, minor
/// limitation of this approach, not a correctness bug for anything older).
public enum SafariHistoryReader {
    public enum ReadError: Error {
        case fileNotReadable
        case unexpectedFormat
    }

    /// Every visit in the (already-copied) database, in no particular
    /// order -- callers needing per-URL rollups (visit count, most recent
    /// visit) should aggregate these themselves, mirroring how
    /// `HistoryStore.importVisits(_:)` folds them into this app's own
    /// per-URL rollup one visit at a time.
    public static func readVisits(fromCopiedDatabaseAt path: String) throws -> [SafariHistoryVisit] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReadError.fileNotReadable
        }
        let connection: SQLiteConnection
        let statement: Statement
        do {
            connection = try SQLiteConnection(path: path, readOnly: true)
            statement = try connection.prepare("""
                SELECT history_items.url, history_visits.title, history_visits.visit_time
                FROM history_visits
                JOIN history_items ON history_visits.history_item = history_items.id;
                """)
        } catch {
            throw ReadError.unexpectedFormat
        }

        var visits: [SafariHistoryVisit] = []
        while try statement.step() {
            let url = statement.text(0)
            guard !url.isEmpty else { continue }
            let title = statement.textOrNil(1)
            let visitTime = Date(timeIntervalSinceReferenceDate: statement.double(2))
            visits.append(SafariHistoryVisit(url: url, title: title, visitTime: visitTime))
        }
        return visits
    }
}
