import Foundation

/// Where one Safari profile's history goes during the ongoing Safari
/// history sync. Keyed by the Safari profile's folder UUID (or
/// `safari-default` for the top-level profile), never by its display name:
/// the folder UUID is the only identifier that is stable on disk.
public enum SafariHistorySyncTarget: Codable, Equatable {
    /// The app's default sync destination (the profile named "Personal",
    /// else the app's fallback profile). Every unmapped Safari profile
    /// gets this.
    case defaultProfile
    /// A browser profile, by `Profile.id`.
    case profile(id: String)
    case skip
}

/// How far one Safari History.db has already been read. Two marks, because
/// neither one alone catches every new row:
///
/// - `lastVisitId` catches visits that iCloud delivers late from another
///   device. Such a row carries its original, older `visit_time`, so a time
///   mark alone skips it forever, but it gets a new, higher row id.
/// - `lastVisitTime` (Safari's own Mac-absolute seconds) catches rows whose
///   id Safari reused after it deleted the newest rows, and every row after
///   Safari rebuilt the file from scratch and restarted its ids.
///
/// A row that passes either mark has never been read, so reading the union
/// never repeats a visit.
public struct SafariHistorySyncCursor: Codable, Equatable {
    public var lastVisitId: Int64
    public var lastVisitTime: Double

    public init(lastVisitId: Int64, lastVisitTime: Double) {
        self.lastVisitId = lastVisitId
        self.lastVisitTime = lastVisitTime
    }

    public static let start = SafariHistorySyncCursor(lastVisitId: 0, lastVisitTime: 0)
}

/// The persisted sync settings and progress, one JSON file per
/// profiles root.
public struct SafariHistorySyncSettings: Codable, Equatable {
    public var isEnabled: Bool
    /// Keyed by Safari profile id. A missing entry means `.defaultProfile`.
    public var targets: [String: SafariHistorySyncTarget]
    /// Keyed by `cursorKey(safariProfileId:browserProfileId:)`, so pointing a
    /// Safari profile at a different browser profile gives that profile the
    /// whole history, not only what arrives after the change.
    public var cursors: [String: SafariHistorySyncCursor]

    public init(isEnabled: Bool = false, targets: [String: SafariHistorySyncTarget] = [:], cursors: [String: SafariHistorySyncCursor] = [:]) {
        self.isEnabled = isEnabled
        self.targets = targets
        self.cursors = cursors
    }

    /// Tolerates missing keys, so a file written by an older build still
    /// loads instead of being moved aside as corrupt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        targets = try container.decodeIfPresent([String: SafariHistorySyncTarget].self, forKey: .targets) ?? [:]
        cursors = try container.decodeIfPresent([String: SafariHistorySyncCursor].self, forKey: .cursors) ?? [:]
    }

    public func target(forSafariProfile safariProfileId: String) -> SafariHistorySyncTarget {
        targets[safariProfileId] ?? .defaultProfile
    }

    public static func cursorKey(safariProfileId: String, browserProfileId: String) -> String {
        "\(safariProfileId)>\(browserProfileId)"
    }

    public func cursor(safariProfileId: String, browserProfileId: String) -> SafariHistorySyncCursor {
        cursors[Self.cursorKey(safariProfileId: safariProfileId, browserProfileId: browserProfileId)] ?? .start
    }

    /// The browser profile id this Safari profile's history goes to, or nil
    /// for none. `eligibleProfileIds` is every profile allowed to receive
    /// synced history -- private-window profiles must never be in it. A
    /// target naming a profile that is no longer eligible (deleted, or
    /// private) falls back to `defaultProfileId`, like an unmapped one.
    public func destinationProfileId(forSafariProfile safariProfileId: String, eligibleProfileIds: Set<String>, defaultProfileId: String?) -> String? {
        let fallback = defaultProfileId.flatMap { eligibleProfileIds.contains($0) ? $0 : nil }
        switch target(forSafariProfile: safariProfileId) {
        case .skip:
            return nil
        case .defaultProfile:
            return fallback
        case .profile(let id):
            return eligibleProfileIds.contains(id) ? id : fallback
        }
    }
}

extension SafariHistoryReader {
    /// Every visit in the (already-copied) database that `cursor` has not
    /// yet covered, plus the cursor to save once those visits are stored.
    /// Same "copied file only" rule as `readVisits(fromCopiedDatabaseAt:)`.
    public static func readVisits(fromCopiedDatabaseAt path: String, after cursor: SafariHistorySyncCursor) throws -> (visits: [SafariHistoryVisit], cursor: SafariHistorySyncCursor) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReadError.fileNotReadable
        }
        let connection: SQLiteConnection
        let maxIdStatement: Statement
        let statement: Statement
        do {
            connection = try SQLiteConnection(path: path, readOnly: true)
            maxIdStatement = try connection.prepare("SELECT COALESCE(MAX(id), 0) FROM history_visits;")
            statement = try connection.prepare("""
                SELECT history_items.url, history_visits.title, history_visits.visit_time
                FROM history_visits
                JOIN history_items ON history_visits.history_item = history_items.id
                WHERE history_visits.id > ? OR history_visits.visit_time > ?;
                """)
        } catch {
            throw ReadError.unexpectedFormat
        }

        let maxId = try maxIdStatement.step() ? maxIdStatement.int64(0) : 0
        // A highest id below the mark means Safari rebuilt the file and
        // restarted its ids, so ids no longer say anything about what was
        // read. The time mark alone decides for this one run.
        let idBound = maxId < cursor.lastVisitId ? Int64.max : cursor.lastVisitId
        try statement.bind(idBound, at: 1)
        try statement.bind(cursor.lastVisitTime, at: 2)

        var visits: [SafariHistoryVisit] = []
        var latestTime = cursor.lastVisitTime
        while try statement.step() {
            let visitTime = statement.double(2)
            latestTime = max(latestTime, visitTime)
            let url = statement.text(0)
            guard !url.isEmpty else { continue }
            visits.append(SafariHistoryVisit(
                url: url,
                title: statement.textOrNil(1),
                visitTime: Date(timeIntervalSinceReferenceDate: visitTime)
            ))
        }
        return (visits, SafariHistorySyncCursor(lastVisitId: maxId, lastVisitTime: latestTime))
    }
}
