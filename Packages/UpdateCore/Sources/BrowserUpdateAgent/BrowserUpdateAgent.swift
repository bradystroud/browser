import Darwin
import Foundation
import UpdateCore

/// Installs a prepared update after Browser quits.
///
/// Usage: BrowserUpdateAgent <update.json> <parent PID>
///
/// Browser copies this helper into the update's staging folder and starts it
/// just before it quits. The helper waits for that process to exit, checks
/// everything again, swaps the staged app in, and, for a restart, opens it and
/// waits for it to confirm that it started. If any step after the swap fails,
/// the previous app goes back in place. A failure is written to
/// `install-error.txt` in the staging folder, where the next launch shows it.
@main
struct BrowserUpdateAgent {
    static func main() {
        var recoveryPlan: ApplicationUpdatePlan?
        var parentExited = false
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 3, let parent = Int32(arguments[2]), parent > 0 else {
                throw ApplicationUpdateError.invalid("Expected an update manifest and the app's PID.")
            }
            let manifest = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let plan = try ApplicationUpdatePlan.load(manifest)
            try ApplicationUpdate.validatePlan(plan, manifest: manifest)
            let superseded = plan.directory.appendingPathComponent("superseded")
            if FileManager.default.fileExists(atPath: superseded.path) { return }
            try ApplicationUpdate.verifyInstalledIdentity(plan.target)
            recoveryPlan = plan
            try ApplicationUpdate.waitForExit(parent)
            if FileManager.default.fileExists(atPath: superseded.path) { return }
            parentExited = true
            try ApplicationUpdate.apply(plan, launch: { app in
                try ApplicationUpdate.run("/usr/bin/open", ["-n", app.path])
                do {
                    try UpdateStartupTrial.waitForStartup(plan)
                } catch {
                    try UpdateStartupTrial.stopUnconfirmedApp(plan)
                    // It may have confirmed while it was being stopped.
                    if UpdateStartupTrial.readReceipt(plan)?.phase == .loaded { return }
                    throw error
                }
            })
            if plan.relaunch { try UpdateStartupTrial.commit(plan) }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            if parentExited, let plan = recoveryPlan {
                do {
                    let message = "The update to \(plan.version) was not installed. " + error.localizedDescription
                    try Data(message.utf8).write(to: plan.directory.appendingPathComponent("install-error.txt"), options: .atomic)
                    if plan.relaunch {
                        try ApplicationUpdate.verifyInstalledIdentity(plan.target)
                        try ApplicationUpdate.run("/usr/bin/open", ["-n", plan.target.path])
                    }
                } catch {
                    FileHandle.standardError.write(Data("Could not reopen the previous app: \(error.localizedDescription)\n".utf8))
                }
            }
            exit(1)
        }
    }
}
