import Foundation
import BrowserCLIProtocol

/// Starts the installed Browser for a command that opens a window (`open`,
/// `window new`, `focus`) when no instance answers, then sends the request
/// once the app's socket accepts it.
///
/// Only for the real instance: with `--socket`, `BROWSER_CLI_SOCKET` or
/// `--profiles-root` the caller named a particular instance, and starting
/// the installed app would not bring that one up. It always starts the
/// installed copy, never the bundle this binary happens to sit in, because
/// a build-tree bundle with no `--profiles-root` would run against the real
/// profiles.
enum AppLauncher {
    static let defaultTimeout: TimeInterval = 30

    static func installedAppCandidates(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications/Browser.app", "\(home)/Applications/Browser.app"]
    }

    static func installedAppPath(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        installedAppCandidates().first(where: fileExists)
    }

    /// Whether this invocation targets the real instance through discovery,
    /// the only case in which the CLI may start the app itself.
    static func mayLaunch(args: ParsedArgs, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        args.flags["no-launch"] == nil
            && args.flags["socket"] == nil
            && args.flags["profiles-root"] == nil
            && environment["BROWSER_CLI_SOCKET"] == nil
    }

    static func send(_ request: CLIRequest, args: ParsedArgs) throws -> CLIResponse {
        guard mayLaunch(args: args) else {
            return try SocketTargetResolver.send(request, args: args)
        }
        let socketPath = try SocketTargetResolver.resolve(args: args)
        do {
            return try SocketClient.send(request, socketPath: socketPath)
        } catch SocketClientError.noRunningInstance {
            try launch()
            return try sendWhenReady(request, socketPath: socketPath, timeout: defaultTimeout)
        }
    }

    private static func launch() throws {
        guard let appPath = installedAppPath() else {
            throw SimpleError("Browser is not running, and no installed Browser.app was found in \(installedAppCandidates().joined(separator: " or ")).")
        }
        // `open` goes through LaunchServices, so the app is attributed to
        // itself (not to this terminal) and starts as a normal launch would.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath, "--args", "--no-default-window"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SimpleError("Could not start \(appPath) (open exited with status \(process.terminationStatus)).")
        }
    }

    /// The request is resent only while the connection itself fails, which
    /// happens before any byte is written, so the app never receives it twice.
    private static func sendWhenReady(_ request: CLIRequest, socketPath: String, timeout: TimeInterval) throws -> CLIResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try SocketClient.send(request, socketPath: socketPath)
            } catch SocketClientError.noRunningInstance {
                guard Date() < deadline else {
                    throw SimpleError("Started Browser, but it did not answer on \(String(reflecting: socketPath)) within \(Int(timeout)) seconds.")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}
