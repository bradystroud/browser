import CryptoKit
import Darwin
import Foundation
import OSLog
import Security

/// A private, durable handoff to the signed helper, which installs only after the app has exited.
public struct ApplicationUpdatePlan: Codable, Sendable, Equatable {
    public var id = UUID()
    public let target: URL
    public let staged: URL
    public let directory: URL
    public let version: String
    public let sourceVersion: String
    public var relaunch = true
    public var manifestURL: URL { directory.appendingPathComponent("update.json") }
    public var agentURL: URL { directory.appendingPathComponent(ApplicationUpdate.agentName) }

    public init(target: URL, staged: URL, directory: URL, version: String, sourceVersion: String) {
        self.target = target
        self.staged = staged
        self.directory = directory
        self.version = version
        self.sourceVersion = sourceVersion
    }

    /// Writes the private handoff manifest atomically for the detached installer.
    public func save() throws {
        try JSONEncoder().encode(self).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    public static func load(_ manifest: URL) throws -> ApplicationUpdatePlan {
        try JSONDecoder().decode(ApplicationUpdatePlan.self, from: Data(contentsOf: manifest))
    }
}

public enum ApplicationUpdateError: Error, LocalizedError {
    case invalid(String)
    case startupFailed(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .startupFailed(let message): message }
    }
}

/// Downloads a release, verifies who made it, stages it beside the app, and swaps it in.
///
/// Trust comes from the code signature, never from the download's location:
/// every bundle that is staged or installed must carry a Developer ID
/// signature from `teamIdentifier` with the expected identifier, and Gatekeeper
/// must say Apple notarized it. The SHA-256 from GitHub's API only proves the
/// download is the file the release lists.
public enum ApplicationUpdate {
    private struct StageOwner: Codable {
        let target: URL
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    public static let bundleIdentifier = "dev.stroud.browser"
    public static let teamIdentifier = "AQ6HPWB3D9"
    public static let agentName = "BrowserUpdateAgent"
    public static let agentIdentifier = bundleIdentifier + ".update-agent"
    public static let executableName = "Browser"
    public static let appName = "Browser.app"
    /// Stamped into Info.plist by scripts/release.sh only. A build without it
    /// came from a developer's machine, and is never installed or replaced.
    public static let releaseBuildKey = "BRWReleaseBuild"
    static let stagePrefix = ".browser-update-"
    static let stageSuffix = ".noindex"

    // MARK: - Process helpers

    /// Waits on the process's own exit event rather than polling a PID that could be reused.
    public static func waitForExit(_ pid: pid_t, seconds: Int = 120) throws {
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw invalid("Could not watch the exiting app.") }
        defer { close(descriptor) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(descriptor, &change, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH { return }
            throw invalid("Could not watch the exiting app: \(String(cString: strerror(errno)))")
        }
        var result = kevent(), timeout = timespec(tv_sec: seconds, tv_nsec: 0)
        guard kevent(descriptor, nil, 0, &result, 1, &timeout) == 1 else {
            throw invalid("Browser did not quit, so the prepared update was left untouched.")
        }
        guard result.flags & UInt16(EV_ERROR) == 0, result.fflags & UInt32(NOTE_EXIT) != 0 else {
            throw invalid("Could not confirm that Browser quit, so the prepared update was left untouched.")
        }
    }

    /// Positional arguments keep paths and remote release data out of shell source.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws {
        _ = try runOutput(executable, arguments, timeout: timeout)
    }

    /// Runs a fixed executable with a deadline, and keeps at most 64 KB of its output.
    public static func runOutput(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> Data {
        let files = FileManager.default
        let logURL = files.temporaryDirectory.appendingPathComponent("browser-update-log-\(UUID().uuidString)")
        guard files.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw invalid("Could not create a private update verification log.")
        }
        defer { try? files.removeItem(at: logURL) }
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            throw invalid("\(URL(fileURLWithPath: executable).lastPathComponent) timed out. The update was not applied.")
        }
        let input = try FileHandle(forReadingFrom: logURL)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let log = try input.read(upToCount: 65_536) ?? Data()
        guard process.terminationStatus == 0 else {
            throw invalid("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(String(decoding: log, as: UTF8.self))")
        }
        return log
    }

    // MARK: - Installing

    /// The installed app must still be the version the update was prepared against.
    public static func validateSource(_ plan: ApplicationUpdatePlan) throws {
        let data = try Data(contentsOf: plan.target.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let installed = AppVersion(info["CFBundleShortVersionString"] as? String ?? ""),
              installed == AppVersion(plan.sourceVersion),
              let candidate = AppVersion(plan.version), candidate > installed else {
            throw invalid("The installed app changed, or this update is not newer. Check for updates again.")
        }
    }

    /// Swaps the staged app in. If anything after the swap fails -- including
    /// the new app not confirming its startup -- the previous app is swapped back.
    public static func apply(
        _ plan: ApplicationUpdatePlan,
        validateBundle: (URL, String) throws -> Void = validate,
        exchange: (URL, URL) throws -> Void = exchange,
        launch: (URL) throws -> Void = { try run("/usr/bin/open", ["-n", $0.path]) }
    ) throws {
        try validateSource(plan)
        try validateBundle(plan.staged, plan.version)
        try UpdateStartupTrial.begin(plan)
        do { try exchange(plan.target, plan.staged) }
        catch { try? UpdateStartupTrial.clear(plan); throw error }
        do {
            try validateBundle(plan.target, plan.version)
            if plan.relaunch { try launch(plan.target) }
        } catch {
            let installationError = error
            do {
                try exchange(plan.target, plan.staged)
                try UpdateStartupTrial.clear(plan)
                try Data("rolled back".utf8).write(to: plan.directory.appendingPathComponent("superseded"), options: .atomic)
            } catch {
                throw invalid("Update rollback could not finish. The previous app is kept at \(plan.staged.path). \(error.localizedDescription)")
            }
            throw installationError
        }
    }

    /// Exchanges two bundles on one volume in a single step. The previous app
    /// stays whole at the other path, for rollback.
    public static func exchange(_ a: URL, _ b: URL) throws {
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw invalid("Could not replace the app: \(String(cString: strerror(errno)))")
        }
    }

    /// Tests the app's real volume before anything is downloaded, so a volume
    /// that cannot swap never reaches the point where the user is asked to quit.
    public static func probeAtomicSwap(in directory: URL) throws {
        let a = directory.appendingPathComponent("swap-probe-a"), b = directory.appendingPathComponent("swap-probe-b")
        let files = FileManager.default
        try files.createDirectory(at: a, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: a) }
        try files.createDirectory(at: b, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: b) }
        guard renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw invalid("This volume cannot replace the app safely: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Preparing

    /// Downloads and verifies a release into a private folder beside the app.
    /// The running app's bundle is not touched.
    public static func prepare(
        release: AppRelease, target: URL, sourceVersion: String,
        progress: @escaping @Sendable (String) async -> Void,
        downloadProgress: (@Sendable (_ received: Int, _ expected: Int64) -> Void)? = nil
    ) async throws -> ApplicationUpdatePlan {
        guard let asset = release.asset else { throw invalid("This release has no verified download yet.") }
        var arm64: Int32 = 0, arm64Size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nil, 0) == 0, arm64 == 1 else {
            throw invalid("Browser updates need an Apple silicon Mac.")
        }
        guard let source = AppVersion(sourceVersion), release.version > source else {
            throw invalid("The update must be newer than the running app.")
        }
        let files = FileManager.default
        guard !target.path.contains("/AppTranslocation/"),
              target.pathExtension == "app", target.standardizedFileURL == target.resolvingSymlinksInPath(),
              files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw invalid("Browser cannot write to the folder it is in. Move Browser to your Applications folder, then try again.")
        }
        let directory = target.deletingLastPathComponent()
            .appendingPathComponent("\(stagePrefix)\(UUID().uuidString)\(stageSuffix)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? files.removeItem(at: directory) } }
        var creator = proc_bsdinfo()
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &creator, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
            throw invalid("Could not identify the process that owns the update folder.")
        }
        let owner = StageOwner(target: target, pid: getpid(), startSeconds: creator.pbi_start_tvsec,
                               startMicroseconds: creator.pbi_start_tvusec)
        try JSONEncoder().encode(owner).write(to: directory.appendingPathComponent("stage-owner.json"), options: .atomic)
        try probeAtomicSwap(in: directory)
        await progress("Downloading Browser \(release.version)…")
        let dmg = directory.appendingPathComponent("update.dmg")
        try await ReleaseDownload(url: asset.url, destination: dmg, progress: downloadProgress).download()
        try Task.checkCancellation()
        await progress("Verifying the download, its signature and notarization…")
        let plan = try await Task.detached {
            let files = FileManager.default
            guard try digest(dmg) == asset.sha256 else { throw invalid("The download failed its SHA-256 check.") }
            try run("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement(identifier: nil), dmg.path])
            try assessNotarized(dmg, diskImage: true)
            let mount = directory.appendingPathComponent("volume", isDirectory: true)
            try files.createDirectory(at: mount, withIntermediateDirectories: false)
            try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
            defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
            let staged = directory.appendingPathComponent(appName, isDirectory: true)
            let mountedApp = mount.appendingPathComponent(appName)
            try validate(mountedApp, version: release.version.description)
            try run("/usr/bin/ditto", [mountedApp.path, staged.path])
            try validate(staged, version: release.version.description)
            // The helper that runs is the running app's own, already trusted
            // one, copied out so it never runs from inside a bundle it swaps.
            let helper = target.appendingPathComponent("Contents/MacOS/\(agentName)")
            try verifySignature(helper, identifier: agentIdentifier)
            try files.copyItem(at: helper, to: directory.appendingPathComponent(agentName))
            let plan = ApplicationUpdatePlan(target: target, staged: staged, directory: directory,
                                             version: release.version.description, sourceVersion: sourceVersion)
            try plan.save()
            try files.removeItem(at: dmg)
            return plan
        }.value
        try Task.checkCancellation()
        complete = true
        await progress("The update is verified and ready. Browser changes only when it restarts.")
        return plan
    }

    // MARK: - Verification

    /// Checks a bundle again just before each swap: a stale or changed staged app is never installed.
    public static func validate(_ app: URL, version: String) throws {
        guard app.standardizedFileURL == app.resolvingSymlinksInPath(),
              (try FileManager.default.attributesOfItem(atPath: app.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw invalid("The update app must be a real folder, not a link.")
        }
        try verifySignature(app, identifier: bundleIdentifier)
        try assessNotarized(app, diskImage: false)
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let expected = AppVersion(version),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              AppVersion(info["CFBundleShortVersionString"] as? String ?? "") == expected,
              info[releaseBuildKey] as? Bool == true else {
            throw invalid("The downloaded app is not the release this update expects.")
        }
        try verifySignature(app.appendingPathComponent("Contents/MacOS/\(agentName)"), identifier: agentIdentifier)
        guard try containsArm64(app.appendingPathComponent("Contents/MacOS/\(executableName)")) else {
            throw invalid("The update does not contain an Apple silicon executable.")
        }
    }

    /// Only an owner-private staging folder beside the app may supply an installation handoff.
    public static func validatePlan(_ plan: ApplicationUpdatePlan, manifest: URL) throws {
        guard isStageName(plan.directory.lastPathComponent),
              manifest.standardizedFileURL == plan.manifestURL.standardizedFileURL,
              plan.directory.deletingLastPathComponent().standardizedFileURL.path == plan.target.deletingLastPathComponent().standardizedFileURL.path,
              plan.target.pathExtension == "app", plan.staged.path == plan.directory.appendingPathComponent(appName).path,
              plan.target.standardizedFileURL == plan.target.resolvingSymlinksInPath(),
              plan.directory.standardizedFileURL == plan.directory.resolvingSymlinksInPath(),
              plan.staged.standardizedFileURL == plan.staged.resolvingSymlinksInPath(),
              AppVersion(plan.version) != nil, AppVersion(plan.sourceVersion) != nil else {
            throw invalid("The prepared update has unexpected paths or versions.")
        }
        for url in [plan.directory, manifest] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                throw invalid("The prepared update is not private to your account.")
            }
        }
    }

    /// The fixed Developer ID requirement keeps a valid signature from another publisher out.
    public static func verifySignature(_ url: URL, identifier: String) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement(identifier: identifier), url.path])
    }

    /// Checks the installed app's executable and Info.plist identity only. A
    /// download is always checked in full by `validate`.
    public static func verifyInstalledIdentity(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", "--ignore-resources", "-R",
                                     requirement(identifier: bundleIdentifier), app.path])
    }

    /// Whether the running bundle is one the updater may replace: a release
    /// build with its helper, signed by this publisher.
    public static func canReplace(_ app: URL) -> Bool {
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info[releaseBuildKey] as? Bool == true,
              FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/\(agentName)").path) else {
            return false
        }
        return (try? verifyInstalledIdentity(app)) != nil
    }

    /// Pins trust to Apple's Developer ID chain and this publisher's team. A
    /// `nil` identifier accepts any identifier from the team (the DMG's own).
    static func requirement(identifier: String?) -> String {
        var text = "=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        if let identifier { text += " and identifier \"\(identifier)\"" }
        return text
    }

    /// Gatekeeper's verdict must come from notarization, not from a rule the user added.
    public static func assessNotarized(_ url: URL, diskImage: Bool) throws {
        var arguments = ["--assess", "--raw", "--type", diskImage ? "open" : "execute"]
        if diskImage { arguments += ["--context", "context:primary-signature"] }
        arguments.append(url.path)
        let data = try runOutput("/usr/sbin/spctl", arguments)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["assessment:verdict"] as? Bool == true,
              let authority = info["assessment:authority"] as? [String: Any],
              authority["assessment:authority:source"] as? String == "Notarized Developer ID" else {
            throw invalid("Gatekeeper did not confirm that Apple notarized this update.")
        }
    }

    /// Hashes the file in 1 MB pieces, so the DMG is never held in memory.
    public static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the Mach-O header directly, without developer tools such as lipo.
    public static func containsArm64(_ executable: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: executable)
        defer { try? input.close() }
        let data = try input.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, little: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let bytes = data[(data.startIndex + offset)..<(data.startIndex + offset + 4)]
            return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0, little: false) else { return false }
        if magic == 0xcffaedfe { return word(4, little: true) == 0x0100000c }
        if magic == 0xfeedfacf { return word(4, little: false) == 0x0100000c }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
        guard [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic),
              let count = word(4, little: little), count > 0, count <= 32 else { return false }
        return (0..<Int(count)).contains { word(8 + $0 * (fat64 ? 32 : 20), little: little) == 0x0100000c }
    }

    // MARK: - Staging folders

    static func isStageName(_ name: String) -> Bool {
        name.hasPrefix(stagePrefix) && name.hasSuffix(stageSuffix)
            && UUID(uuidString: String(name.dropFirst(stagePrefix.count).dropLast(stageSuffix.count))) != nil
    }

    /// This user's private staging folders beside `app`, oldest name order.
    public static func stagingFolders(beside app: URL) -> [URL] {
        let parent = app.deletingLastPathComponent()
        // Built from the app's own parent path rather than taken from the
        // listing, which may spell the same folder another way (/private/var).
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return [] }
        return names.sorted().map { parent.appendingPathComponent($0, isDirectory: true) }
            .filter { isPrivateStage($0, beside: app) }
    }

    /// Accepts only this user's private UUID staging folders beside the app.
    private static func isPrivateStage(_ directory: URL, beside app: URL) -> Bool {
        guard isStageName(directory.lastPathComponent),
              directory.deletingLastPathComponent().standardizedFileURL.path == app.deletingLastPathComponent().standardizedFileURL.path,
              directory.standardizedFileURL == directory.resolvingSymlinksInPath(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { return false }
        return true
    }

    /// A message the helper left in a staging folder after it could not
    /// install. Reading it marks that folder finished.
    public static func takeInstallError(beside app: URL) -> String? {
        var message: String?
        for directory in stagingFolders(beside: app) {
            let file = directory.appendingPathComponent("install-error.txt")
            guard let data = try? Data(contentsOf: file) else { continue }
            message = String(decoding: data, as: UTF8.self)
            try? FileManager.default.removeItem(at: file)
            try? Data("failed".utf8).write(to: directory.appendingPathComponent("superseded"), options: .atomic)
        }
        return message
    }

    /// Deletes finished or orphaned staging folders. A folder is kept while a
    /// process runs from it, while it is the prepared update, or while its
    /// install has not been confirmed (it holds the rollback copy).
    public static func pruneCompletedUpdates(for app: URL, keeping pending: URL? = nil) {
        let files = FileManager.default
        guard let running = runningExecutablePaths() else { return }
        for directory in stagingFolders(beside: app) {
            let manifest = directory.appendingPathComponent("update.json")
            guard manifest.path != pending?.path,
                  !running.contains(where: { $0.hasPrefix(directory.path + "/") }) else { continue }
            let completed = files.fileExists(atPath: directory.appendingPathComponent("applied").path)
                || files.fileExists(atPath: directory.appendingPathComponent("superseded").path)
            let inTrial = files.fileExists(atPath: directory.appendingPathComponent(UpdateStartupTrial.trialFileName).path)
            if !completed {
                // Never delete a folder whose swap happened but was not confirmed:
                // after the swap it holds the previous app.
                guard !inTrial else { continue }
                let ownerData = try? Data(contentsOf: directory.appendingPathComponent("stage-owner.json"))
                guard let owner = ownerData.flatMap({ try? JSONDecoder().decode(StageOwner.self, from: $0) }),
                      owner.target.standardizedFileURL.path == app.standardizedFileURL.path,
                      isCreatorGone(owner) else { continue }
            }
            do {
                let volume = directory.appendingPathComponent("volume")
                if files.fileExists(atPath: volume.path),
                   let root = try volume.resourceValues(forKeys: [.volumeURLKey]).volume,
                   root.resolvingSymlinksInPath().path == volume.resolvingSymlinksInPath().path {
                    try run("/usr/bin/hdiutil", ["detach", volume.path])
                }
                try files.removeItem(at: directory)
            } catch {
                Logger(subsystem: bundleIdentifier, category: "updates")
                    .error("Kept update staging folder after cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Marks a prepared update as replaced, so its helper never installs it,
    /// and deletes it unless a process still runs from it.
    public static func retirePreparedUpdate(_ plan: ApplicationUpdatePlan) throws {
        try validatePlan(plan, manifest: plan.manifestURL)
        try Data("superseded".utf8).write(to: plan.directory.appendingPathComponent("superseded"), options: .atomic)
        guard let running = runningExecutablePaths(),
              !running.contains(where: { $0.hasPrefix(plan.directory.path + "/") }) else { return }
        try FileManager.default.removeItem(at: plan.directory)
    }

    /// The executable path of every process this user runs, or `nil` when
    /// the list cannot be read completely (callers then delete nothing).
    private static func runningExecutablePaths() -> [String]? {
        let capacity = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size + 64)
        let count = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var running: [String] = []
        for pid in pids.prefix(Int(count) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                if errno == ESRCH || errno == ENOENT { continue }
                return nil
            }
            running.append(String(cString: path))
        }
        return running
    }

    /// The folder's creator must have exited before an unfinished download is deleted.
    private static func isCreatorGone(_ owner: StageOwner) -> Bool {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, &info, expected) != expected {
            return kill(owner.pid, 0) == -1 && errno == ESRCH
        }
        return info.pbi_uid != geteuid() || info.pbi_start_tvsec != owner.startSeconds
            || info.pbi_start_tvusec != owner.startMicroseconds
    }

    static func invalid(_ message: String) -> ApplicationUpdateError { .invalid(message) }
}
