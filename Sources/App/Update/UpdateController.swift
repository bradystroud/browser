import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread whenever anything `UpdateController` shows changes.
    static let updateStateDidChange = Notification.Name("BrowserUpdateStateDidChange")
}

/// Checks GitHub for a newer release, and downloads, verifies and stages it
/// when the user asks. Nothing is installed until Browser quits or restarts;
/// then `BrowserUpdateAgent` swaps the staged app in (see Packages/UpdateCore).
@MainActor
final class UpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(AppVersion)
        case available(AppRelease)
        case failed(String)

        var release: AppRelease? {
            guard case .available(let release) = self else { return nil }
            return release
        }
    }

    enum Installation: Equatable {
        case ready
        case running
        case installed
        case failed(String)
    }

    /// How this copy can be updated.
    enum Route: Equatable {
        /// A release build with its helper, in a folder it can write to.
        case native
        /// Anything else -- a build from source, or a copy that cannot replace
        /// itself. The release page has the download.
        case releasePage
    }

    static let checkInterval: TimeInterval = 60 * 60 * 24
    /// The due check is cheap, so poll often enough that a Mac waking from
    /// sleep does not wait another whole interval to notice it is due.
    private static let pollInterval: TimeInterval = 60 * 60

    private enum Key {
        static let automaticChecks = "updates.automaticChecks"
        static let lastCheckedAt = "updates.lastCheckedAt"
        static let knownTag = "updates.knownRelease.tag"
        static let knownURL = "updates.knownRelease.url"
        static let knownAssetURL = "updates.knownRelease.assetURL"
        static let knownAssetSHA = "updates.knownRelease.assetSHA256"
        static let skippedVersion = "updates.skippedVersion"
        static let stagedManifest = "updates.stagedManifest"
    }

    let currentVersion: String
    let route: Route
    /// Whether this build came from the release pipeline. A local build has
    /// the template's version, so it would always look out of date: it checks
    /// only when asked.
    let isReleaseBuild: Bool

    private(set) var status: Status = .idle { didSet { changed() } }
    private(set) var installation: Installation = .ready { didSet { changed() } }
    private(set) var installationOutput = "" { didSet { changed() } }
    /// 0...1 while the DMG downloads with a known size, otherwise `nil`.
    private(set) var downloadFraction: Double? { didSet { changed() } }
    private(set) var lastCheckedAt: Date? { didSet { changed() } }
    /// A release the user chose not to be reminded about. Only that exact
    /// version goes quiet: a newer release brings the button back.
    private(set) var skippedVersion: AppVersion? { didSet { changed() } }
    private(set) var stagedUpdate: ApplicationUpdatePlan? { didSet { changed() } }
    private(set) var isPreparingRestart = false { didSet { changed() } }
    /// Set once the helper has been started for a restart, so quitting does
    /// not start a second, install-only helper.
    private(set) var isRestartingForUpdate = false

    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            defaults.set(automaticallyChecks, forKey: Key.automaticChecks)
            if automaticallyChecks && isReleaseBuild { startPolling() } else { stopPolling() }
            changed()
        }
    }

    private let defaults: UserDefaults
    private let bundleURL: URL
    private let now: () -> Date
    private let fetch: @Sendable (URL) async throws -> Data
    private var poll: Timer?
    private var inFlightCheck: Task<Status, Never>?

    init(
        defaults: UserDefaults = AppPreferencesStore.current,
        bundleURL: URL = Bundle.main.bundleURL,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        isReleaseBuild: Bool = Bundle.main.object(forInfoDictionaryKey: ApplicationUpdate.releaseBuildKey) as? Bool == true,
        now: @escaping () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.defaults = defaults
        self.bundleURL = bundleURL
        self.currentVersion = currentVersion
        self.isReleaseBuild = isReleaseBuild
        self.now = now
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        }
        route = isReleaseBuild && ApplicationUpdate.canReplace(bundleURL) ? .native : .releasePage
        automaticallyChecks = defaults.object(forKey: Key.automaticChecks) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Key.lastCheckedAt) as? Date
        skippedVersion = defaults.string(forKey: Key.skippedVersion).flatMap(AppVersion.init)
        // A known update is shown again at once after a relaunch, rather than
        // staying quiet until the next check falls due.
        status = Self.restoredStatus(currentVersion: currentVersion, defaults: defaults)
        restoreStagedUpdate()
    }

    func start() {
        if automaticallyChecks && isReleaseBuild { startPolling() }
        Task { await checkIfDue() }
    }

    private func changed() {
        NotificationCenter.default.post(name: .updateStateDidChange, object: self)
    }

    // MARK: - Checking

    /// The release the toolbar button offers. A skipped version stays in
    /// `status`, so "Check for Updates…" still reports it when asked.
    var unskippedRelease: AppRelease? {
        guard let release = status.release, release.version != skippedVersion else { return nil }
        return release
    }

    func skip(_ release: AppRelease) {
        skippedVersion = release.version
        defaults.set(release.version.description, forKey: Key.skippedVersion)
    }

    var isDueForCheck: Bool {
        guard let lastCheckedAt else { return true }
        return now().timeIntervalSince(lastCheckedAt) >= Self.checkInterval
    }

    func checkIfDue() async {
        guard automaticallyChecks, isReleaseBuild, isDueForCheck else { return }
        await check()
    }

    /// A second caller joins the check already running. Two checks in flight
    /// would let whichever answer came last win, not the one asked for last.
    @discardableResult
    func check() async -> Status {
        if let inFlightCheck { return await inFlightCheck.value }
        let task = Task { @MainActor in await performCheck() }
        inFlightCheck = task
        let result = await task.value
        inFlightCheck = nil
        return result
    }

    private func performCheck() async -> Status {
        status = .checking
        do {
            let data = try await fetch(ReleaseCheck.latestReleaseEndpoint)
            switch try ReleaseCheck.availability(currentVersion: currentVersion, latestReleaseJSON: data) {
            case .upToDate(let version):
                status = .upToDate(version)
                forgetKnownRelease()
            case .available(let release):
                status = .available(release)
                remember(release)
            }
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        // Recorded either way: a failed check that retried on every poll
        // would hammer the API while offline.
        lastCheckedAt = now()
        defaults.set(lastCheckedAt, forKey: Key.lastCheckedAt)
        return status
    }

    private func remember(_ release: AppRelease) {
        defaults.set(release.tag, forKey: Key.knownTag)
        defaults.set(release.releaseURL.absoluteString, forKey: Key.knownURL)
        defaults.set(release.asset?.url.absoluteString, forKey: Key.knownAssetURL)
        defaults.set(release.asset?.sha256, forKey: Key.knownAssetSHA)
    }

    private func forgetKnownRelease() {
        for key in [Key.knownTag, Key.knownURL, Key.knownAssetURL, Key.knownAssetSHA] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Rebuilds a remembered release, but only when it is still newer and its
    /// download address is exactly the release's own.
    private static func restoredStatus(currentVersion: String, defaults: UserDefaults) -> Status {
        guard let tag = defaults.string(forKey: Key.knownTag),
              let version = AppVersion(tag),
              let address = defaults.string(forKey: Key.knownURL), let url = URL(string: address),
              url.scheme == "https", url.host == "github.com",
              let current = AppVersion(currentVersion), version > current else { return .idle }
        let expected = "https://github.com/\(ReleaseCheck.repository)/releases/download/\(tag)/\(ReleaseCheck.assetName(for: version))"
        var asset: AppRelease.Asset?
        if defaults.string(forKey: Key.knownAssetURL) == expected, let download = URL(string: expected),
           let digest = defaults.string(forKey: Key.knownAssetSHA), ReleaseCheck.isSHA256(digest) {
            asset = .init(url: download, sha256: digest)
        }
        return .available(AppRelease(version: version, tag: tag, releaseURL: url, asset: asset))
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        // Common modes, so a check still fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: - Installing

    /// The state shown for one release, without confusing it with a different staged one.
    func installation(for release: AppRelease) -> Installation {
        if installation == .running { return .running }
        if let stagedUpdate, AppVersion(stagedUpdate.version) == release.version { return .installed }
        return installation == .installed ? .ready : installation
    }

    var canRestartAfterUpdate: Bool {
        installation != .running && !isPreparingRestart && stagedUpdate != nil
    }

    /// Downloads, verifies and stages `release`. Checking is separate: a
    /// timer cannot erase progress or start a second download.
    func install(release requested: AppRelease) async {
        guard installation != .running, route == .native else { return }
        guard installation(for: requested) != .installed else { return }
        installation = .running
        installationOutput = ""
        downloadFraction = nil
        do {
            var release = requested
            if release.asset == nil {
                // GitHub adds an asset's digest a little after the release
                // appears, so ask again before giving up.
                let data = try await fetch(ReleaseCheck.latestReleaseEndpoint)
                guard let refreshed = try ReleaseCheck.availability(currentVersion: currentVersion, latestReleaseJSON: data).release,
                      refreshed.tag == release.tag, refreshed.asset != nil else {
                    throw ApplicationUpdateError.invalid("The release changed, or its verified download is not ready yet. Check for updates again.")
                }
                release = refreshed
                remember(refreshed)
            }
            let prepared = try await ApplicationUpdate.prepare(
                release: release, target: bundleURL, sourceVersion: currentVersion,
                progress: { [weak self] message in await self?.appendOutput(message) },
                downloadProgress: { [weak self] received, expected in
                    guard expected > 0 else { return }
                    let fraction = min(1, Double(received) / Double(expected))
                    Task { @MainActor in self?.setDownloadFraction(fraction) }
                })
            if let previous = stagedUpdate {
                do { try ApplicationUpdate.retirePreparedUpdate(previous) }
                catch { appendOutput("Could not remove the previously prepared update: \(error.localizedDescription)") }
            }
            stagedUpdate = prepared
            defaults.set(prepared.manifestURL.path, forKey: Key.stagedManifest)
            downloadFraction = nil
            installation = .installed
        } catch {
            downloadFraction = nil
            installation = .failed(error.localizedDescription)
        }
    }

    private func setDownloadFraction(_ fraction: Double) {
        // About a hundred steps is enough for a progress bar; every chunk would be thousands.
        guard installation == .running, abs(fraction - (downloadFraction ?? -1)) >= 0.01 || fraction == 1 else { return }
        downloadFraction = fraction
    }

    private func appendOutput(_ line: String) {
        installationOutput += (installationOutput.isEmpty ? "" : "\n") + line
    }

    private func restoreStagedUpdate() {
        guard let path = defaults.string(forKey: Key.stagedManifest) else { return }
        let manifest = URL(fileURLWithPath: path)
        do {
            let plan = try ApplicationUpdatePlan.load(manifest)
            if let staged = AppVersion(plan.version), let current = AppVersion(currentVersion), staged <= current {
                // Already installed: this launch is that version.
                defaults.removeObject(forKey: Key.stagedManifest)
                return
            }
            try ApplicationUpdate.validatePlan(plan, manifest: manifest)
            guard !FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("superseded").path) else {
                throw ApplicationUpdateError.invalid("The prepared update was replaced. Check for updates again.")
            }
            guard plan.target.standardizedFileURL.path == bundleURL.standardizedFileURL.path,
                  plan.sourceVersion == currentVersion else {
                throw ApplicationUpdateError.invalid("The prepared update belongs to a different copy of Browser.")
            }
            stagedUpdate = plan
            installation = .installed
        } catch {
            defaults.removeObject(forKey: Key.stagedManifest)
            installation = .failed("Could not restore the prepared update: \(error.localizedDescription)")
        }
    }

    /// A deleted or changed handoff must never block quitting.
    func disarmPreparedUpdate(_ reason: String) {
        stagedUpdate = nil
        defaults.removeObject(forKey: Key.stagedManifest)
        installation = .failed(reason)
    }

    /// Reports a failure the helper left behind at the last quit.
    func reportInstallFailure(_ message: String) {
        defaults.removeObject(forKey: Key.stagedManifest)
        stagedUpdate = nil
        installation = .failed(message)
    }

    // MARK: - Handing off to the helper

    /// Checks the staged bundle in full again, off the main thread, then
    /// returns the helper for a restart.
    func verifiedRestartHelper() async throws -> Process {
        guard let plan = stagedUpdate else { throw ApplicationUpdateError.invalid("No update is prepared.") }
        guard !isPreparingRestart else { throw ApplicationUpdateError.invalid("The update is already being checked.") }
        isPreparingRestart = true
        defer { isPreparingRestart = false }
        try await Task.detached {
            try ApplicationUpdate.validatePlan(plan, manifest: plan.manifestURL)
            try ApplicationUpdate.validateSource(plan)
            try ApplicationUpdate.validate(plan.staged, version: plan.version)
            try ApplicationUpdate.verifySignature(plan.agentURL, identifier: ApplicationUpdate.agentIdentifier)
        }.value
        return try helper(relaunch: true)
    }

    /// The helper process for the staged update, ready to run. Only cheap
    /// checks happen here, so the quit path can call it; the helper checks
    /// everything again before it swaps.
    func helper(relaunch: Bool) throws -> Process {
        guard var plan = stagedUpdate else { throw ApplicationUpdateError.invalid("No update is prepared.") }
        try ApplicationUpdate.validatePlan(plan, manifest: plan.manifestURL)
        guard !FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("superseded").path) else {
            throw ApplicationUpdateError.invalid("The prepared update was replaced. Check for updates again.")
        }
        plan.relaunch = relaunch
        try plan.save()
        stagedUpdate = plan
        let process = Process()
        process.executableURL = plan.agentURL
        process.arguments = [plan.manifestURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    func markRestartingForUpdate() { isRestartingForUpdate = true }
}
