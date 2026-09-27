import Foundation
import BrowserCLIProtocol

/// `browser open <url> [--profile <name>] [--new-window | --little]` -- talks to a
/// running instance's `CLIServer` (Sources/App/CLI/CLIServer.swift); there is
/// no disk-only fallback, since actually opening a window/tab requires the
/// live app.
public enum OpenCommand {
    public static func run(args: ParsedArgs) -> Bool {
        guard let url = args.positionals.first else {
            return Output.emitError("usage: browser open <url> [--profile <name>] [--new-window | --little]", json: args.jsonOutput)
        }
        if args.flags["new-window"] != nil && args.flags["little"] != nil {
            return Output.emitError("--little and --new-window can't be combined", json: args.jsonOutput)
        }

        var requestArgs = ["url": url]
        if let profile = args.flags["profile"] { requestArgs["profile"] = profile }
        // A bare switch, so ArgParser parsed it as `--new-window` with an
        // empty value (or, if a value followed, whatever that was) -- its
        // mere presence is the signal, hence `!= nil` rather than a value
        // comparison. The wire format keeps args a flat [String: String]
        // (see CLIRequest), so "true" is how a boolean travels.
        if args.flags["new-window"] != nil { requestArgs["new-window"] = "true" }
        // A small single-page window (the app's LittleWindowController)
        // instead of a tab.
        if args.flags["little"] != nil { requestArgs["little"] = "true" }

        let socketPath = CLISocketPath.path(inDirectory: DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments))
        do {
            let response = try SocketClient.send(CLIRequest(command: "open", args: requestArgs), socketPath: socketPath)
            guard response.ok else {
                return Output.emitError(response.error ?? "open failed", json: args.jsonOutput)
            }
            return Output.emit(response, json: args.jsonOutput) { $0.message ?? "Opened \(url)." }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
