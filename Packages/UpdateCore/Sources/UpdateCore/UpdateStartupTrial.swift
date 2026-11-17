import Darwin
import Foundation

/// The new app confirms that it really started, after its first window is up.
/// LaunchServices accepting `open` is not proof of that.
///
/// The record lives in the update's own staging folder: `trial` (written
/// before the swap) says the folder holds the previous app; `applied` (written
/// when the new app confirms) says the folder may be deleted.
public enum UpdateStartupTrial {
    public struct Receipt: Codable, Sendable {
        public enum Phase: String, Codable, Sendable { case loaded, failed }
        public let id: UUID
        public let phase: Phase
        public let pid: Int32
        public let seconds: UInt64
        public let microseconds: UInt64
        public let message: String?
    }

    static let trialFileName = "trial"
    static func trialURL(_ plan: ApplicationUpdatePlan) -> URL { plan.directory.appendingPathComponent(trialFileName) }
    static func receiptURL(_ plan: ApplicationUpdatePlan) -> URL { plan.directory.appendingPathComponent("startup-receipt.json") }

    /// Clears an earlier attempt's receipt and records the trial, before the swap.
    public static func begin(_ plan: ApplicationUpdatePlan) throws {
        let receipt = receiptURL(plan)
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        try Data(plan.id.uuidString.utf8).write(to: trialURL(plan), options: .atomic)
    }

    /// The trial the running app must confirm: one beside `app` for exactly
    /// this version, swapped in and not yet confirmed.
    public static func pending(beside app: URL, version: String) -> ApplicationUpdatePlan? {
        let files = FileManager.default
        for directory in ApplicationUpdate.stagingFolders(beside: app) {
            let manifest = directory.appendingPathComponent("update.json")
            guard let plan = try? ApplicationUpdatePlan.load(manifest),
                  (try? ApplicationUpdate.validatePlan(plan, manifest: manifest)) != nil,
                  plan.target.standardizedFileURL.path == app.standardizedFileURL.path,
                  AppVersion(plan.version) == AppVersion(version),
                  let trial = try? Data(contentsOf: trialURL(plan)),
                  String(decoding: trial, as: UTF8.self) == plan.id.uuidString,
                  !files.fileExists(atPath: directory.appendingPathComponent("applied").path),
                  !files.fileExists(atPath: directory.appendingPathComponent("superseded").path) else { continue }
            return plan
        }
        return nil
    }

    /// Records this process's identity with the phase, so a reused PID can never confirm the trial.
    public static func report(_ phase: Receipt.Phase, plan: ApplicationUpdatePlan, message: String? = nil) throws {
        var info = proc_bsdinfo()
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
            throw ApplicationUpdateError.invalid("Could not identify this process to confirm the update.")
        }
        let receipt = Receipt(id: plan.id, phase: phase, pid: getpid(), seconds: info.pbi_start_tvsec,
                              microseconds: info.pbi_start_tvusec, message: message)
        try JSONEncoder().encode(receipt).write(to: receiptURL(plan), options: .atomic)
    }

    /// A receipt from a different update is never accepted for this one.
    public static func readReceipt(_ plan: ApplicationUpdatePlan) -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL(plan)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.id == plan.id else { return nil }
        return receipt
    }

    /// The receipt's PID must still be this user's process, started at the
    /// recorded time, running the installed app's executable.
    public static func matches(_ receipt: Receipt, plan: ApplicationUpdatePlan) -> Bool {
        var info = proc_bsdinfo()
        guard receipt.pid > 0,
              proc_pidinfo(receipt.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == geteuid(), info.pbi_start_tvsec == receipt.seconds,
              info.pbi_start_tvusec == receipt.microseconds else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(receipt.pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == plan.target.appendingPathComponent("Contents/MacOS/\(ApplicationUpdate.executableName)").path
    }

    /// Waits for the new app's "loaded" receipt.
    public static func waitForStartup(_ plan: ApplicationUpdatePlan, seconds: TimeInterval = 120) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let receipt = readReceipt(plan) {
                switch receipt.phase {
                case .loaded: return
                case .failed: throw ApplicationUpdateError.startupFailed(receipt.message ?? "The new version could not finish starting.")
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ApplicationUpdateError.startupFailed("The new version did not finish starting within \(Int(seconds)) seconds.")
    }

    /// Stops a new app that never confirmed its startup, and only that process.
    public static func stopUnconfirmedApp(_ plan: ApplicationUpdatePlan) throws {
        guard let receipt = readReceipt(plan), receipt.phase != .loaded, matches(receipt, plan: plan) else { return }
        _ = kill(receipt.pid, SIGTERM)
        do { try ApplicationUpdate.waitForExit(receipt.pid, seconds: 10) }
        catch {
            guard matches(receipt, plan: plan) else { return }
            _ = kill(receipt.pid, SIGKILL)
            try ApplicationUpdate.waitForExit(receipt.pid, seconds: 5)
        }
    }

    public static func clear(_ plan: ApplicationUpdatePlan) throws {
        let trial = trialURL(plan)
        if FileManager.default.fileExists(atPath: trial.path) { try FileManager.default.removeItem(at: trial) }
    }

    /// The previous app in the folder may be deleted from now on.
    public static func commit(_ plan: ApplicationUpdatePlan) throws {
        try Data("applied".utf8).write(to: plan.directory.appendingPathComponent("applied"), options: .atomic)
        try clear(plan)
    }
}
