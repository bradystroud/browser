import Foundation

/// Where a flushed batch of tallies goes. A protocol so the recorder -- the
/// part that decides *what* is worth recording -- has no opinion about
/// SQLite and can be tested without one.
protocol TrackerReportSink: AnyObject {
    /// Called on the main thread with one profile's accumulated counts.
    /// Implementations must treat this as additive: the same tally can
    /// arrive again on a later flush with a further count.
    func addTrackerBlocks(_ counts: [TrackerBlockTally: Int], forProfileId profileId: String)
}

/// Buffers blocked-request events in memory and hands them to a sink in
/// batches (browser-e7r).
///
/// WHY AGGREGATE RATHER THAN LOG. The signal behind this is one delegate
/// callback per cancelled resource request, and a single ad-heavy page can
/// produce hundreds. Writing a row per request would mean tens of thousands
/// of inserts on a normal browsing day, for data whose only questions are
/// "which trackers, on which sites, how often, over 30 days" -- all of which
/// a per-day count answers exactly as well. So the in-memory shape is a
/// counter keyed by (day, page host, tracker domain), and the store sees one
/// transaction per flush instead of one per request. The tally type and the
/// day arithmetic both live with the store (BrowserCore's
/// TrackerReportStore), so there is one definition of what a day is rather
/// than one on each side of the boundary.
///
/// WHAT IS COUNTED, PRECISELY, because the existing per-tab badge counts
/// something different and a report built on the wrong noun would be a lie:
///
/// - `requestCount` is resource requests cancelled. One tracker serving
///   forty requests to a page is forty.
/// - A *tracker* is one distinct `trackerDomain` -- and that is the block
///   list entry that matched, not the request's own host, so
///   "stats.g.doubleclick.net" and "ad.doubleclick.net" are one tracker
///   ("doubleclick.net") rather than two. Any headline counting trackers
///   must count distinct domains, never sum requestCount.
/// - Reloading a page adds to the same day's tally rather than starting
///   over, unlike Tab.blockedRequestCount, which resets on every main-frame
///   load. That is why the per-page badge and this report legitimately
///   disagree, and why summing badge values over time would inflate.
///
/// PRIVATE WINDOWS record nothing at all -- see `record`. Blocking still
/// happens in them (ContentBlockerCoordinator gives the "private"
/// pseudo-profile an always-enabled snapshot), and the shield popover still
/// shows its live per-tab count, which dies with the window. A privacy
/// feature that kept a durable record of private browsing would be
/// self-defeating.
final class TrackerReportRecorder {
    /// Flush cadence. Long enough that a page loading a hundred trackers is
    /// one write rather than a hundred, short enough that a hard kill loses
    /// at most a few seconds of counts -- data whose whole purpose is a
    /// 30-day trend does not justify durability guarantees beyond that.
    private static let flushInterval: TimeInterval = 15

    /// A hard ceiling on how much can accumulate between flushes, so a
    /// pathological page cannot grow the buffer without bound if the timer
    /// is starved. Counted in distinct tallies, not requests: repeated hits
    /// on the same tracker only ever bump an existing counter.
    private static let maxBufferedTallies = 2_000

    static let shared = TrackerReportRecorder()

    weak var sink: TrackerReportSink?

    private var buffer: [String: [TrackerBlockTally: Int]] = [:]
    private var flushTimer: Timer?
    /// Injectable only so tests can pin a date; production always uses now.
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Records one cancelled request. `pageHost` is the host of the page the
    /// request was made from and `trackerDomain` is the block list entry
    /// that matched it, both already lowercased by the caller's own host
    /// derivation.
    ///
    /// Returns silently for a private tab, for a page with no host (a
    /// blocked request from the start page or a data: URL), and for an empty
    /// tracker domain. Each of those is a normal occurrence rather than an
    /// error worth surfacing.
    func record(trackerDomain: String, pageHost: String, profileId: String, isPrivate: Bool) {
        guard !isPrivate, !profileId.isEmpty, !pageHost.isEmpty, !trackerDomain.isEmpty else { return }

        let tally = TrackerBlockTally(
            day: TrackerReportStore.startOfDay(for: clock()),
            pageHost: pageHost.lowercased(),
            trackerDomain: trackerDomain.lowercased()
        )
        buffer[profileId, default: [:]][tally, default: 0] += 1

        if bufferedTallyCount >= Self.maxBufferedTallies {
            flush()
        } else {
            scheduleFlush()
        }
    }

    /// Writes everything buffered and stops the timer. Called on the flush
    /// timer, when the buffer hits its ceiling, and at quit -- the last of
    /// which is the one that matters, since otherwise the final few seconds
    /// of a session are lost every time.
    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard let sink, !buffer.isEmpty else {
            buffer.removeAll()
            return
        }
        let pending = buffer
        buffer.removeAll()
        for (profileId, counts) in pending {
            sink.addTrackerBlocks(counts, forProfileId: profileId)
        }
    }

    private var bufferedTallyCount: Int {
        buffer.values.reduce(0) { $0 + $1.count }
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }
}
