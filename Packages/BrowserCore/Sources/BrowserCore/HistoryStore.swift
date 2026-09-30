import Foundation

public struct HistoryEntry: Equatable {
    public let url: String
    public let title: String
    public let visitCount: Int
    public let lastVisitTime: Date

    public init(url: String, title: String, visitCount: Int, lastVisitTime: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitTime = lastVisitTime
    }
}

public struct HistorySuggestion: Equatable {
    public let url: String
    public let title: String
    public let score: Double
}

/// Per-profile visit history: a rollup row per URL (`history_urls`, used for
/// autocomplete/ranking) backed by an append-only visit log
/// (`history_visits`, used for range deletes and recomputing the rollup).
public final class HistoryStore {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func recordVisit(url: String, title: String?, at date: Date = Date()) throws {
        try database.perform { db in
            try db.withTransaction {
                try Self.insertVisit(url: url, title: title, at: date, db: db)
            }
        }
    }

    /// Sets the stored title of an already-recorded URL. A visit is recorded
    /// when a navigation commits, which is before the new page has told us
    /// its title, so the real title arrives through here afterwards. Does
    /// nothing for a URL that was never recorded, for an empty title, or for
    /// a title equal to the stored one -- pages that animate their title
    /// report it many times a second, and each of those would otherwise be
    /// a write.
    public func updateTitle(url: String, title: String) throws {
        try setTitle(url: url, title: title)
    }

    /// updateTitle, reporting whether a row actually changed.
    @discardableResult
    func setTitle(url: String, title: String) throws -> Bool {
        guard !title.isEmpty else { return false }
        return try database.perform { db in
            let update = try db.prepare("UPDATE history_urls SET title = ? WHERE url = ? AND title != ?;")
            try update.bind(title, at: 1)
            try update.bind(url, at: 2)
            try update.bind(title, at: 3)
            try update.step()
            return db.changes > 0
        }
    }

    /// Bulk variant for importing another browser's history (browser-ymx's
    /// Safari import) -- one shared transaction for the whole batch rather
    /// than one per visit (recordVisit's own per-call transaction is fine
    /// for real-time recording, but would mean thousands of individual
    /// fsync'd commits for an import of a whole history file). Each
    /// visit's own real historical timestamp is preserved (not "now"), so
    /// the same rollup + individual-visit-row bookkeeping recordVisit
    /// itself relies on -- and therefore deleteRange's later recompute --
    /// stays exactly as consistent as if these had been recorded for real,
    /// one at a time, as they originally happened. Order doesn't matter:
    /// insertVisit takes the max of the existing and new last_visit_time,
    /// never regresses it backward regardless of which order visits are
    /// replayed in.
    public func importVisits(_ visits: [(url: String, title: String?, visitTime: Date)]) throws {
        try database.perform { db in
            try db.withTransaction {
                for visit in visits {
                    try Self.insertVisit(url: visit.url, title: visit.title, at: visit.visitTime, db: db)
                }
            }
        }
    }

    /// importVisits, minus every visit this profile already holds: one with
    /// the same URL at the same millisecond. Imported visits keep their
    /// original timestamps, so this recognizes a visit that an earlier
    /// one-time Safari import or sync run already brought in. Returns how
    /// many visits it inserted.
    @discardableResult
    public func importVisitsSkippingExisting(_ visits: [(url: String, title: String?, visitTime: Date)]) throws -> Int {
        try database.perform { db in
            var inserted = 0
            try db.withTransaction {
                let exists = try db.prepare("""
                    SELECT 1 FROM history_visits
                    JOIN history_urls ON history_visits.url_id = history_urls.id
                    WHERE history_urls.url = ? AND history_visits.visit_time = ?
                    LIMIT 1;
                    """)
                for visit in visits {
                    try exists.bind(visit.url, at: 1)
                    try exists.bind(Self.epochMs(visit.visitTime), at: 2)
                    let alreadyHeld = try exists.step()
                    try exists.reset()
                    if alreadyHeld { continue }
                    try Self.insertVisit(url: visit.url, title: visit.title, at: visit.visitTime, db: db)
                    inserted += 1
                }
            }
            return inserted
        }
    }

    private static func insertVisit(url: String, title: String?, at date: Date, db: SQLiteConnection) throws {
        let epochMs = epochMs(date)
        let resolvedTitle = title ?? ""
        let select = try db.prepare("SELECT id FROM history_urls WHERE url = ?;")
        try select.bind(url, at: 1)
        let urlId: Int64
        if try select.step() {
            urlId = select.int64(0)
            let update = try db.prepare("""
                UPDATE history_urls
                SET visit_count = visit_count + 1,
                    last_visit_time = MAX(last_visit_time, ?),
                    title = CASE WHEN ? != '' THEN ? ELSE title END
                WHERE id = ?;
                """)
            try update.bind(epochMs, at: 1)
            try update.bind(resolvedTitle, at: 2)
            try update.bind(resolvedTitle, at: 3)
            try update.bind(urlId, at: 4)
            try update.step()
        } else {
            let insert = try db.prepare("""
                INSERT INTO history_urls (url, title, visit_count, last_visit_time)
                VALUES (?, ?, 1, ?);
                """)
            try insert.bind(url, at: 1)
            try insert.bind(resolvedTitle, at: 2)
            try insert.bind(epochMs, at: 3)
            try insert.step()
            urlId = db.lastInsertRowID
        }
        let visitInsert = try db.prepare("INSERT INTO history_visits (url_id, visit_time) VALUES (?, ?);")
        try visitInsert.bind(urlId, at: 1)
        try visitInsert.bind(epochMs, at: 2)
        try visitInsert.step()
    }

    /// Ranked candidates for omnibox autocomplete: substring match against
    /// URL or title, scored by frecency (visit count weighted by recency)
    /// with a bonus for matches at the start of the host, highest first.
    public func autocomplete(query: String, limit: Int = 8, now: Date = Date()) throws -> [HistorySuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let likePattern = "%\(Self.escapeLike(trimmed))%"
        let nowMs = Self.epochMs(now)

        let rows: [(url: String, title: String, visitCount: Int, lastVisitTime: Int64)] = try database.perform { db in
            let stmt = try db.prepare("""
                SELECT url, title, visit_count, last_visit_time
                FROM history_urls
                WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
                ORDER BY last_visit_time DESC
                LIMIT 500;
                """)
            try stmt.bind(likePattern, at: 1)
            try stmt.bind(likePattern, at: 2)
            var results: [(String, String, Int, Int64)] = []
            while try stmt.step() {
                results.append((stmt.text(0), stmt.text(1), stmt.int(2), stmt.int64(3)))
            }
            return results
        }

        let needle = trimmed.lowercased()
        let scored = rows.map { row -> HistorySuggestion in
            let host = Self.normalizedHost(row.url).lowercased()
            let titleLower = row.title.lowercased()
            let prefixBonus: Double
            if host.hasPrefix(needle) {
                prefixBonus = 3.0
            } else if titleLower.hasPrefix(needle) {
                prefixBonus = 2.0
            } else {
                prefixBonus = 1.0
            }
            let ageMs = max(0, nowMs - row.lastVisitTime)
            let score = Double(row.visitCount) * Self.recencyMultiplier(ageMs: ageMs) * prefixBonus
            return HistorySuggestion(url: row.url, title: row.title, score: score)
        }

        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Top entries by frecency (visit count weighted by recency) -- for
    /// surfaces like the start page's "Frequently Visited" section, where
    /// (unlike autocomplete(query:)) there's no text filter: every history
    /// entry is a candidate, ranked purely by frecency, highest first.
    /// Shares autocomplete's own 500-row candidate cap (the most recently
    /// visited 500 URLs) before ranking, rather than scoring the entire
    /// table -- consistent with that method, and enough of a candidate
    /// pool that a genuinely-frequent site is never the 501st most recent.
    public func topFrecent(limit: Int = 8, now: Date = Date()) throws -> [HistoryEntry] {
        let nowMs = Self.epochMs(now)

        let rows: [(url: String, title: String, visitCount: Int, lastVisitTime: Int64)] = try database.perform { db in
            let stmt = try db.prepare("""
                SELECT url, title, visit_count, last_visit_time
                FROM history_urls
                ORDER BY last_visit_time DESC
                LIMIT 500;
                """)
            var results: [(String, String, Int, Int64)] = []
            while try stmt.step() {
                results.append((stmt.text(0), stmt.text(1), stmt.int(2), stmt.int64(3)))
            }
            return results
        }

        let scored = rows.map { row -> (entry: HistoryEntry, score: Double) in
            let ageMs = max(0, nowMs - row.lastVisitTime)
            let score = Double(row.visitCount) * Self.recencyMultiplier(ageMs: ageMs)
            let entry = HistoryEntry(
                url: row.url,
                title: row.title,
                visitCount: row.visitCount,
                lastVisitTime: Date(timeIntervalSince1970: Double(row.lastVisitTime) / 1000)
            )
            return (entry, score)
        }

        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0.entry }
    }

    /// Rollup entries (one per URL) for the "Show All History" window,
    /// newest-first, optionally filtered by a substring in URL or title.
    public func entries(matching text: String? = nil, limit: Int = 500) throws -> [HistoryEntry] {
        try database.perform { db in
            let stmt: Statement
            if let text, !text.isEmpty {
                stmt = try db.prepare("""
                    SELECT url, title, visit_count, last_visit_time
                    FROM history_urls
                    WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
                    ORDER BY last_visit_time DESC
                    LIMIT ?;
                    """)
                let pattern = "%\(Self.escapeLike(text))%"
                try stmt.bind(pattern, at: 1)
                try stmt.bind(pattern, at: 2)
                try stmt.bind(Int64(limit), at: 3)
            } else {
                stmt = try db.prepare("""
                    SELECT url, title, visit_count, last_visit_time
                    FROM history_urls
                    ORDER BY last_visit_time DESC
                    LIMIT ?;
                    """)
                try stmt.bind(Int64(limit), at: 1)
            }
            var results: [HistoryEntry] = []
            while try stmt.step() {
                results.append(HistoryEntry(
                    url: stmt.text(0),
                    title: stmt.text(1),
                    visitCount: stmt.int(2),
                    lastVisitTime: Date(timeIntervalSince1970: Double(stmt.int64(3)) / 1000)
                ))
            }
            return results
        }
    }

    public func deleteItem(url: String) throws {
        try database.perform { db in
            let stmt = try db.prepare("DELETE FROM history_urls WHERE url = ?;")
            try stmt.bind(url, at: 1)
            try stmt.step()
        }
    }

    /// Deletes every visit in `[from, to]` and recomputes affected rollups,
    /// dropping any URL left with zero remaining visits.
    public func deleteRange(from: Date, to: Date) throws {
        let fromMs = Self.epochMs(from)
        let toMs = Self.epochMs(to)
        try database.perform { db in
            try db.withTransaction {
                let delete = try db.prepare("DELETE FROM history_visits WHERE visit_time BETWEEN ? AND ?;")
                try delete.bind(fromMs, at: 1)
                try delete.bind(toMs, at: 2)
                try delete.step()

                try db.execute("""
                    UPDATE history_urls
                    SET visit_count = (SELECT COUNT(*) FROM history_visits WHERE url_id = history_urls.id),
                        last_visit_time = COALESCE(
                            (SELECT MAX(visit_time) FROM history_visits WHERE url_id = history_urls.id), 0)
                    """)
                try db.execute("DELETE FROM history_urls WHERE visit_count = 0;")
            }
        }
    }

    public func deleteAll() throws {
        try database.perform { db in
            try db.execute("DELETE FROM history_urls;")
        }
    }

    private static func epochMs(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func escapeLike(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func normalizedHost(_ url: String) -> String {
        var result = url
        for prefix in ["https://", "http://"] {
            if result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                break
            }
        }
        if result.hasPrefix("www.") {
            result.removeFirst(4)
        }
        return result
    }

    /// Firefox-style frecency buckets: recent visits are worth far more than
    /// old ones, but old-and-frequent still beats new-and-rare.
    private static func recencyMultiplier(ageMs: Int64) -> Double {
        let hour: Int64 = 3_600_000
        switch ageMs {
        case ..<(4 * hour): return 100
        case ..<(24 * hour): return 70
        case ..<(7 * 24 * hour): return 50
        case ..<(30 * 24 * hour): return 30
        default: return 10
        }
    }
}
