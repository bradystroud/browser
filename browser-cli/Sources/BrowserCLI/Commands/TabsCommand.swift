import Foundation
import BrowserCLIProtocol

/// `browser tabs [--profile <name>]` -- window/index/title/URL for every
/// open tab. Requires a running instance: open tabs are in-memory state
/// (`WindowManager`/`BrowserWindowController`), not something persisted to
/// disk in real time (only a debounced session snapshot is -- see
/// SessionStore -- which could be stale by the time this runs).
public enum TabsCommand {
    public static func run(args: ParsedArgs) -> Bool {
        var requestArgs: [String: String] = [:]
        if let profile = args.flags["profile"] { requestArgs["profile"] = profile }

        let socketPath = CLISocketPath.path(inDirectory: DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments))
        do {
            let response = try SocketClient.send(CLIRequest(command: "tabs", args: requestArgs), socketPath: socketPath)
            guard response.ok else {
                return Output.emitError(response.error ?? "tabs failed", json: args.jsonOutput)
            }
            return Output.emit(response, json: args.jsonOutput) { response in
                guard let tabs = response.tabs, !tabs.isEmpty else { return "(no open tabs)" }
                return tabs.map { tab in
                    let marker = tab.isActive ? "*" : (tab.isAsleep == true ? "z" : " ")
                    return "\(marker) \(tab.profileName)\twindow \(tab.windowIndex) tab \(tab.tabIndex)\t\(tab.title)\t\(tab.url)"
                }.joined(separator: "\n")
            }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
