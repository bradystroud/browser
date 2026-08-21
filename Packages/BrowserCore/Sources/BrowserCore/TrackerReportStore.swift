import Foundation

/// One day's "this tracker was blocked on this page", already aggregated --
/// the unit both the in-app recorder and this store deal in. Never one row
/// per blocked request: see TrackerReportStore's own doc comment.
///
/// `day` is the start of the local calendar day, as epoch seconds. Local
/// rather than UTC because a person's "last 30 days" is their own calendar's;
/// the cost is that a bucket spanning a DST change or a flight is a day of
/// that person's life rather than exactly 86400 seconds, which is the right
/// trade for a report a human reads.
public struct TrackerBlockTally: Hashable {
    public let day: Int
    public let pageHost: String
    public let trackerDomain: String

    public init(day: Int, pageHost: String, trackerDomain: String) {
        self.day = day
        self.pageHost = pageHost
        self.trackerDomain = trackerDomain
    }
}

/// One tracker in a report, with both numbers it can honestly be described
/// by: how many requests it made, and how many distinct sites it turned up
/// on. The second is usually the more interesting one -- a tracker present
/// on forty of your sites is a different thing from one that made forty
/// requests to a single page.
public struct TrackerReportEntry: Equatable {
    public let trackerDomain: String
    public let requestCount: Int
    public let siteCount: Int
}

/// One day's totals, for a trend line.
public struct TrackerReportDay: Equatable {
    public let day: Int
    public let trackerCount: Int
    public let requestCount: Int
}

/// The 30-day headline.
///
/// `trackerCount` is DISTINCT TRACKER DOMAINS and is the only number that
/// may be labelled "trackers". `requestCount` is resource requests
/// cancelled, which is a much larger number measuring something else; it
/// must never be presented as a count of trackers. See TrackerReportStore.
public struct TrackerReportSummary: Equatable {
    public let trackerCount: Int
    public let siteCount: Int
    public let requestCount: Int
    public let topTrackers: [TrackerReportEntry]
    public let days: [TrackerReportDay]

    public var mostContactedTracker: TrackerReportEntry? { topTrackers.first }

    /// True when there is nothing to report yet -- a fresh profile, or one
    /// whose report was just cleared. Worth distinguishing in the UI from
    /// "we looked and found no trackers", which is a different claim.
    public var isEmpty: Bool { requestCount == 0 }
}

/// Per-profile record of which trackers the content blocker stopped, on
/// which sites, over the last 30 days (browser-e7r).
///
/// AGGREGATED, NOT LOGGED. The signal behind this is one callback per
/// cancelled resource request, and an ad-heavy page produces hundreds. A row
/// per request would be tens of thousands of inserts on a normal day, to
/// answer questions -- which trackers, on which sites, how often, over what
/// period -- that a per-day count answers exactly as well. So the table is
/// keyed by (day, page host, tracker domain) and carries a count that
/// `addTallies` increments, fed from a buffer that batches many requests
/// into one transaction.
///
/// WHAT THE NUMBERS MEAN, stated here because the app's existing per-tab
/// badge counts something different and a report built on the wrong noun
/// would be a lie in a big font:
///
/// - A *tracker* is one distinct `trackerDomain`, and that is the BLOCK LIST
///   ENTRY that matched, not the request's own host -- so
///   "stats.g.doubleclick.net" and "ad.doubleclick.net" are one tracker,
///   "doubleclick.net", rather than two. Count trackers with
///   COUNT(DISTINCT tracker_domain), never by summing request counts.
/// - `request_count` is requests cancelled. One tracker serving forty
///   requests to one page is forty.
/// - Reloading a page adds to the same day's row rather than starting over,
///   unlike Tab.blockedRequestCount which resets on every main-frame load.
///   The per-page badge and this report therefore legitimately disagree, and
///   summing badge values over time would inflate by however often the user
///   reloads.
///
/// PRIVATE WINDOWS never reach here at all -- the recorder drops them before
/// this store is ever asked to write. Blocking still happens in a private
/// window and its live per-tab count still shows; only the durable record is
/// refused.
///
/// ITS OWN DATABASE FILE, separate from browser.db: this is high-write,
/// disposable data with a 30-day life, and keeping it out of the file that
/// holds history and bookmarks means it can never bloat or corrupt them.
/// That also makes "clear the privacy report" a file deletion rather than a
/// careful set of DELETEs.
public final class TrackerReportStore {
    /// How far back a report looks, and therefore how much is kept. Rows
    /// older than this are deleted rather than merely hidden -- a privacy
    /// feature has no business holding a record it will not show.
    public static let retentionDays = 30

    /// Bumped only for a schema change. Unlike browser.db's ordered
    /// migrations, a mismatch here DROPS the table and starts again: this
    /// data is disposable and rebuilds itself within a day of browsing, so
    /// carrying migration code for it would be more machinery than the
    /// worst case (losing at most 30 days of a report) is worth. That is a
    /// deliberate difference from the durable stores, not an oversight.
    private static let schemaVersion: Int32 = 1

    private let database: Database
    /// The last local day rows were pruned for, so a busy session prunes
    /// once when the date rolls over rather than on every flush.
    private var lastPrunedDay: Int?

    public init(profileDirectory: URL) throws {
        database = try Database(
            profileDirectory: profileDirectory,
            fileName: "privacy-report.db",
            queueLabel: "com.browser.BrowserCore.TrackerReportStore",
            prepareSchema: Self.prepareSchema
        )
    }

    private static func prepareSchema(_ db: SQLiteConnection) throws {
        if db.userVersion != schemaVersion {
            try db.execute("DROP TABLE IF EXISTS tracker_blocks;")
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS tracker_blocks (
            day INTEGER NOT NULL,
            page_host TEXT NOT NULL,
            tracker_domain TEXT NOT NULL,
            request_count INTEGER NOT NULL,
            PRIMARY KEY (day, page_host, tracker_domain)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS idx_tracker_blocks_day ON tracker_blocks(day);
        CREATE INDEX IF NOT EXISTS idx_tracker_blocks_page ON tracker_blocks(page_host, day);
        """)
        try db.setUserVersion(schemaVersion)
    }

    // MARK: - Writing

    /// Adds a batch of counts, incrementing any row that already exists, and
    /// prunes anything past the retention window. One transaction for the
    /// whole batch -- the entire point of the recorder buffering first.
    ///
    /// Additive by design: the same tally arriving again on a later flush
    /// adds to what is there rather than replacing it.
    public func addTallies(_ counts: [TrackerBlockTally: Int], now: Date = Date()) throws {
        guard !counts.isEmpty else { return }
        let cutoff = Self.retentionCutoff(now: now)
        let today = Self.startOfDay(for: now)

        try database.perform { db in
            try db.withTransaction {
                let statement = try db.prepare("""
                INSERT INTO tracker_blocks (day, page_host, tracker_domain, request_count)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(day, page_host, tracker_domain)
                DO UPDATE SET request_count = request_count + excluded.request_count;
                """)
                for (tally, count) in counts where count > 0 && tally.day >= cutoff {
                    try statement.reset()
                    try statement.bind(Int64(tally.day), at: 1)
                    try statement.bind(tally.pageHost, at: 2)
                    try statement.bind(tally.trackerDomain, at: 3)
                    try statement.bind(Int64(count), at: 4)
                    _ = try statement.step()
                }
                if lastPrunedDay != today {
                    let prune = try db.prepare("DELETE FROM tracker_blocks WHERE day < ?;")
                    try prune.bind(Int64(cutoff), at: 1)
                    _ = try prune.step()
                    lastPrunedDay = today
                }
            }
        }
    }

    /// Forgets everything. Wired to a "Clear Privacy Report" action -- the
    /// user asking a privacy feature to stop remembering must be answered
    /// completely, so this deletes rather than hides.
    public func clear() throws {
        try database.perform { db in
            try db.execute("DELETE FROM tracker_blocks;")
        }
        lastPrunedDay = nil
    }

    // MARK: - Reading

    /// The whole-profile report for the retention window.
    ///
    /// `topTrackers` is ordered by sites first, then requests: a tracker
    /// following you across twelve sites is the more meaningful headline
    /// than one that made a lot of requests to a single page.
    public func summary(now: Date = Date(), topTrackerLimit: Int = 10) throws -> TrackerReportSummary {
        let cutoff = Self.retentionCutoff(now: now)
        return try database.perform { db in
            let totals = try db.prepare("""
            SELECT COUNT(DISTINCT tracker_domain), COUNT(DISTINCT page_host), COALESCE(SUM(request_count), 0)
            FROM tracker_blocks WHERE day >= ?;
            """)
            try totals.bind(Int64(cutoff), at: 1)
            var trackerCount = 0
            var siteCount = 0
            var requestCount = 0
            if try totals.step() {
                trackerCount = totals.int(0)
                siteCount = totals.int(1)
                requestCount = totals.int(2)
            }

            let top = try db.prepare("""
            SELECT tracker_domain, SUM(request_count), COUNT(DISTINCT page_host)
            FROM tracker_blocks WHERE day >= ?
            GROUP BY tracker_domain
            ORDER BY COUNT(DISTINCT page_host) DESC, SUM(request_count) DESC, tracker_domain ASC
            LIMIT ?;
            """)
            try top.bind(Int64(cutoff), at: 1)
            try top.bind(Int64(topTrackerLimit), at: 2)
            var topTrackers: [TrackerReportEntry] = []
            while try top.step() {
                topTrackers.append(TrackerReportEntry(
                    trackerDomain: top.text(0), requestCount: top.int(1), siteCount: top.int(2)
                ))
            }

            let daily = try db.prepare("""
            SELECT day, COUNT(DISTINCT tracker_domain), SUM(request_count)
            FROM tracker_blocks WHERE day >= ?
            GROUP BY day ORDER BY day ASC;
            """)
            try daily.bind(Int64(cutoff), at: 1)
            var days: [TrackerReportDay] = []
            while try daily.step() {
                days.append(TrackerReportDay(day: daily.int(0), trackerCount: daily.int(1), requestCount: daily.int(2)))
            }

            return TrackerReportSummary(
                trackerCount: trackerCount,
                siteCount: siteCount,
                requestCount: requestCount,
                topTrackers: topTrackers,
                days: days
            )
        }
    }

    /// The trackers seen on one site over the window, most requests first --
    /// what the shield popover names for the page in front of the user.
    /// `siteCount` on each entry is always 1 here by construction; the type
    /// is shared with the whole-profile report, where it varies.
    public func trackers(forPageHost pageHost: String, now: Date = Date(), limit: Int = 20) throws -> [TrackerReportEntry] {
        let cutoff = Self.retentionCutoff(now: now)
        let host = pageHost.lowercased()
        return try database.perform { db in
            let statement = try db.prepare("""
            SELECT tracker_domain, SUM(request_count)
            FROM tracker_blocks WHERE page_host = ? AND day >= ?
            GROUP BY tracker_domain
            ORDER BY SUM(request_count) DESC, tracker_domain ASC
            LIMIT ?;
            """)
            try statement.bind(host, at: 1)
            try statement.bind(Int64(cutoff), at: 2)
            try statement.bind(Int64(limit), at: 3)
            var entries: [TrackerReportEntry] = []
            while try statement.step() {
                entries.append(TrackerReportEntry(
                    trackerDomain: statement.text(0), requestCount: statement.int(1), siteCount: 1
                ))
            }
            return entries
        }
    }

    // MARK: - Day arithmetic

    /// Start of `date`'s local calendar day, in epoch seconds -- the form
    /// every `day` value in this store takes.
    public static func startOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        Int(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    /// The oldest day a report keeps. Anything strictly older is deleted.
    /// The window counts `days` buckets INCLUDING today, so a 30-day report
    /// spans 30 calendar days rather than 31.
    public static func retentionCutoff(
        now: Date = Date(), days: Int = retentionDays, calendar: Calendar = .current
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return Int(cutoff.timeIntervalSince1970)
    }
}
