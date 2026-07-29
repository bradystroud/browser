import Foundation
import BrowserCLIProtocol

/// `browser open <url> [--profile <name>]` -- talks to a running instance's
/// `CLIServer` (Sources/App/CLI/CLIServer.swift); there is no disk-only
/// fallback, since actually opening a window/tab requires the live app.
public enum OpenCommand {
    public static func run(args: ParsedArgs) -> Bool {
        guard let url = args.positionals.first else {
            return Output.emitError("usage: browser open <url> [--profile <name>]", json: args.jsonOutput)
        }

        var requestArgs = ["url": url]
        if let profile = args.flags["profile"] { requestArgs["profile"] = profile }

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
