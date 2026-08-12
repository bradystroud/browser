import Foundation
import BrowserCLIProtocol

/// `browser window new [<url>] [--profile <name>]` and `browser windows
/// [--profile <name>]` -- both need a running instance (opening a window is
/// inherently live, and so is knowing which windows are open), same as
/// `open`/`tabs`/`profiles`.
///
/// `window new` is the one thing `open` couldn't express: `open` puts a URL
/// in the frontmost window of its target profile when one exists, which is
/// the right default for a link but the wrong answer for "give me a window in
/// this profile." `open --new-window` covers the with-a-URL half of that;
/// this covers the no-URL half, where there's nothing to route on at all.
public enum WindowCommand {
    public static func new(args: ParsedArgs) -> Bool {
        var requestArgs: [String: String] = [:]
        if let profile = args.flags["profile"] { requestArgs["profile"] = profile }
        if let url = args.positionals.first { requestArgs["url"] = url }

        return send(CLIRequest(command: "window-new", args: requestArgs), args: args) { response in
            response.message ?? "Opened a new window."
        }
    }

    /// `browser focus [--profile <name>]` (browser-dpf) -- bring that
    /// profile's frontmost window to the front, opening one if it has none.
    /// Deliberately reuse-or-create in a single round trip; see CLIServer's
    /// handleFocus for why that beats a caller-side focus-then-fall-back
    /// pair.
    public static func focus(args: ParsedArgs) -> Bool {
        var requestArgs: [String: String] = [:]
        // Also accepts the profile as a bare positional (`browser focus Work`),
        // since this is the one command whose only argument *is* the profile
        // and typing the flag adds nothing.
        if let profile = args.flags["profile"] ?? args.positionals.first {
            requestArgs["profile"] = profile
        }

        return send(CLIRequest(command: "focus", args: requestArgs), args: args) { response in
            response.message ?? "Focused."
        }
    }

    public static func list(args: ParsedArgs) -> Bool {
        var requestArgs: [String: String] = [:]
        if let profile = args.flags["profile"] { requestArgs["profile"] = profile }

        return send(CLIRequest(command: "windows", args: requestArgs), args: args) { response in
            guard let windows = response.windows, !windows.isEmpty else { return "(no open windows)" }
            return windows.map { window in
                let privateMarker = window.isPrivate ? " (private)" : ""
                let tabs = "\(window.tabCount) tab\(window.tabCount == 1 ? "" : "s")"
                return "window \(window.windowIndex)\t\(window.profileName)\(privateMarker)\t\(tabs)\t\(window.activeTabTitle)\t\(window.activeTabURL)"
            }.joined(separator: "\n")
        }
    }

    private static func send(_ request: CLIRequest, args: ParsedArgs, text: @escaping (CLIResponse) -> String) -> Bool {
        let socketPath = CLISocketPath.path(inDirectory: DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments))
        do {
            let response = try SocketClient.send(request, socketPath: socketPath)
            guard response.ok else {
                return Output.emitError(response.error ?? "\(request.command) failed", json: args.jsonOutput)
            }
            return Output.emit(response, json: args.jsonOutput, text: text)
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
