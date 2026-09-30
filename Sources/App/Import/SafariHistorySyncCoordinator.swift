import AppKit

extension Notification.Name {
    /// Posted on the main thread whenever the Safari history sync's settings
    /// or status change.
    static let safariHistorySyncDidChange = Notification.Name("SafariHistorySyncDidChange")
}

/// Ongoing, one-way sync of Safari's history into this browser's profiles.
/// Safari's History.db also holds the visits iCloud brings in from the
/// user's other Apple devices, so this is how those reach the omnibox and
/// history search here. Safari's files are only ever copied, never opened
/// or written in place.
///
/// Safari profiles are keyed by `SafariImportScanner.ProfileSource.id`
/// (the profile's external_uuid, or `safari-default`), and history is read
/// from the path the scanner resolves for each one.
///
/// Settings and progress persist in `safari-history-sync.json` under
/// `CommandLineArgs.sessionAndProfilesMetadataDirectory()`, so a
/// `--profiles-root` launch has its own. Each run copies every mapped
/// Safari profile's History.db whose files changed since the last run,
/// reads only the rows past that profile's `SafariHistorySyncCursor`, and
/// stores them with `HistoryStore.importVisitsSkippingExisting`, which also
/// drops visits an earlier one-time import already brought in.
///
/// Settings and status are main-thread state. The reading and writing
/// happen on `queue`, which hops to the main thread only to fetch a
/// profile's stores from `ProfileDataStoreManager`, whose cache is not
/// thread-safe.
final class SafariHistorySyncCoordinator {
    static let shared = SafariHistorySyncCoordinator()

    enum Status: Equatable {
        case notRunYet
        case running
        /// Safari's data is not readable -- normally a missing Full Disk
        /// Access grant, which macOS reports the same way as "no Safari".
        case safariNotReadable
        case synced(at: Date, importedVisits: Int)
    }

    static let interval: TimeInterval = 5 * 60
    /// Every unmapped Safari profile syncs into the browser profile with
    /// this name, or into `ProfileManager.fallbackProfile` when none has it.
    static let defaultDestinationName = "Personal"
    /// Visits per write transaction, so a first sync of a large history
    /// never holds the profile database for long in one go.
    private static let importBatchSize = 2_000

    private let fileURL: URL
    private(set) var settings: SafariHistorySyncSettings
    private(set) var status: Status = .notRunYet
    private var timer: Timer?
    private var isRunning = false
    private var rerunRequested = false
    private let queue = DispatchQueue(label: "dev.stroud.browser.SafariHistorySync", qos: .utility)

    /// The size and modification date of a History.db and its -wal file.
    /// Unchanged means nothing new, so the run skips the copy.
    private struct SourceSignature: Equatable {
        let values: [String]
    }

    /// Keyed like `SafariHistorySyncSettings.cursors`. Only `queue` touches it.
    private var lastSourceSignatures: [String: SourceSignature] = [:]

    private init() {
        let dir = URL(fileURLWithPath: CommandLineArgs.sessionAndProfilesMetadataDirectory())
        fileURL = dir.appendingPathComponent("safari-history-sync.json")
        settings = JSONFile<SafariHistorySyncSettings>(url: fileURL).load(default: SafariHistorySyncSettings())
    }

    /// Starts the first sync a few seconds after launch finishes, and the
    /// periodic timer, when sync is on. Deliberately does not touch
    /// `shared` before then: loading settings needs the launch arguments
    /// resolved, and the first run needs ProfileManager.
    static func startAfterLaunch() {
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                shared.applyEnabledState()
            }
        }
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        save()
        applyEnabledState()
        postChange()
    }

    func setTarget(_ target: SafariHistorySyncTarget, forSafariProfile safariProfileId: String) {
        if target == .defaultProfile {
            settings.targets[safariProfileId] = nil
        } else {
            settings.targets[safariProfileId] = target
        }
        save()
        postChange()
        syncNow()
    }

    /// The profile every unmapped Safari profile syncs into, or nil if the
    /// only candidate is a private-window profile.
    var defaultDestinationProfile: Profile? {
        let profiles = ProfileManager.shared
        let profile = profiles.profile(named: Self.defaultDestinationName) ?? profiles.fallbackProfile
        return profile.isPrivate ? nil : profile
    }

    private func save() {
        JSONFile<SafariHistorySyncSettings>(url: fileURL).save(settings)
    }

    private func postChange() {
        NotificationCenter.default.post(name: .safariHistorySyncDidChange, object: self)
    }

    private func applyEnabledState() {
        timer?.invalidate()
        timer = nil
        guard settings.isEnabled else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.syncNow()
        }
        timer.tolerance = 30
        self.timer = timer
        syncNow()
    }

    // MARK: - Sync

    func syncNow() {
        guard settings.isEnabled else { return }
        guard !isRunning else {
            rerunRequested = true
            return
        }
        isRunning = true
        let previousStatus = status
        status = .running
        postChange()

        let snapshot = settings
        let eligibleProfiles = ProfileManager.shared.profiles.filter { !$0.isPrivate }
        let defaultProfileId = defaultDestinationProfile?.id
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.runSync(settings: snapshot, eligibleProfiles: eligibleProfiles, defaultProfileId: defaultProfileId)
            DispatchQueue.main.async {
                self.finish(outcome, previousStatus: previousStatus)
            }
        }
    }

    private struct Outcome {
        var safariNotReadable = false
        var importedVisits = 0
        var cursors: [String: SafariHistorySyncCursor] = [:]
    }

    /// Runs on `queue`.
    private func runSync(settings: SafariHistorySyncSettings, eligibleProfiles: [Profile], defaultProfileId: String?) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("SafariHistorySync-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            NSLog("SafariHistorySync: could not create %@: %@", tempDir.path, String(describing: error))
            return outcome
        }
        guard let sources = SafariImportScanner.locateSources(tempDirectory: tempDir) else {
            outcome.safariNotReadable = true
            return outcome
        }

        let eligibleIds = Set(eligibleProfiles.map(\.id))
        for safariProfile in sources.profiles {
            let safariProfileId = safariProfile.id
            guard let source = safariProfile.historyPath,
                  let destinationId = settings.destinationProfileId(
                    forSafariProfile: safariProfileId, eligibleProfileIds: eligibleIds, defaultProfileId: defaultProfileId
                  ) else { continue }

            let key = SafariHistorySyncSettings.cursorKey(safariProfileId: safariProfileId, browserProfileId: destinationId)
            let signature = Self.signature(of: source.path)
            if lastSourceSignatures[key] == signature { continue }

            let copy = tempDir.appendingPathComponent("\(safariProfileId)-History.db").path
            guard SafariImportScanner.copySQLiteDatabase(from: source.path, to: copy) else {
                outcome.safariNotReadable = true
                continue
            }

            do {
                let result = try SafariHistoryReader.readVisits(
                    fromCopiedDatabaseAt: copy,
                    after: settings.cursor(safariProfileId: safariProfileId, browserProfileId: destinationId)
                )
                if !result.visits.isEmpty {
                    guard let history = Self.historyStore(forProfileId: destinationId) else { continue }
                    let visits = result.visits.map { (url: $0.url, title: $0.title, visitTime: $0.visitTime) }
                    for start in stride(from: 0, to: visits.count, by: Self.importBatchSize) {
                        let batch = Array(visits[start..<min(start + Self.importBatchSize, visits.count)])
                        outcome.importedVisits += try history.importVisitsSkippingExisting(batch)
                    }
                }
                outcome.cursors[key] = result.cursor
                lastSourceSignatures[key] = signature
            } catch {
                // The cursor stays put, so the next run retries these rows,
                // and any batch already stored is skipped as existing.
                NSLog("SafariHistorySync: Safari profile %@ -> %@ failed: %@", safariProfileId, destinationId, String(describing: error))
            }
        }
        return outcome
    }

    /// Hops to the main thread, where `ProfileDataStoreManager` lives, and
    /// re-checks that the profile still exists and is not private.
    private static func historyStore(forProfileId profileId: String) -> HistoryStore? {
        DispatchQueue.main.sync {
            guard let profile = ProfileManager.shared.profile(id: profileId), !profile.isPrivate else { return nil }
            return ProfileDataStoreManager.shared.stores(for: profile).history
        }
    }

    private static func signature(of databasePath: String) -> SourceSignature {
        let fm = FileManager.default
        let values = [databasePath, databasePath + "-wal"].map { path -> String in
            guard let attributes = try? fm.attributesOfItem(atPath: path) else { return "-" }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            return "\(size)@\(modified)"
        }
        return SourceSignature(values: values)
    }

    private func finish(_ outcome: Outcome, previousStatus: Status) {
        for (key, cursor) in outcome.cursors {
            settings.cursors[key] = cursor
        }
        if !outcome.cursors.isEmpty {
            save()
        }
        if outcome.safariNotReadable {
            // Logged once per change, not on every periodic tick.
            if previousStatus != .safariNotReadable {
                NSLog("SafariHistorySync: Safari's data is not readable; Full Disk Access is probably not granted")
            }
            status = .safariNotReadable
        } else {
            status = .synced(at: Date(), importedVisits: outcome.importedVisits)
        }
        isRunning = false
        postChange()
        if rerunRequested {
            rerunRequested = false
            syncNow()
        }
    }

    // MARK: - Discovery for Settings

    /// Lists Safari's profiles for the Settings pane, or nil when Safari's
    /// data is not readable. Runs on `queue`, so it never copies Safari's
    /// files at the same time as a sync run.
    func discoverSafariProfiles(completion: @escaping ([SafariImportScanner.ProfileSource]?) -> Void) {
        queue.async {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("SafariHistorySync-\(UUID().uuidString)")
            var profiles: [SafariImportScanner.ProfileSource]?
            if (try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)) != nil {
                profiles = SafariImportScanner.locateSources(tempDirectory: tempDir)?.profiles
                try? fm.removeItem(at: tempDir)
            }
            DispatchQueue.main.async {
                completion(profiles)
            }
        }
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
