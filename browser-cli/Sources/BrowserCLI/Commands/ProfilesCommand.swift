import Foundation
import BrowserCLIProtocol

/// `browser profiles` -- name/id/colour/live window count. Requires a
/// running instance for the live window count (see CLIServer.handleProfiles);
/// unlike `route-test`/`history`/`bookmarks`, there's no meaningful
/// disk-only fallback, since "is a window open" is inherently live state.
public enum ProfilesCommand {
    public static func run(args: ParsedArgs) -> Bool {
        let socketPath = CLISocketPath.path(inDirectory: DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments))
        do {
            let response = try SocketClient.send(CLIRequest(command: "profiles"), socketPath: socketPath)
            guard response.ok else {
                return Output.emitError(response.error ?? "profiles failed", json: args.jsonOutput)
            }
            return Output.emit(response, json: args.jsonOutput) { response in
                guard let profiles = response.profiles, !profiles.isEmpty else { return "(no profiles)" }
                return profiles.map { profile in
                    "\(profile.name)\t\(profile.id)\t\(profile.colorHex)\twindows=\(profile.windowCount)"
                }.joined(separator: "\n")
            }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
