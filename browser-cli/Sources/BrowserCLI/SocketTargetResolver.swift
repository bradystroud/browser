import Foundation
import BrowserCLIProtocol

/// Client-only targeting; the listener continues to use its system temp directory.
enum SocketTargetResolver {
    static func validate(_ path: String, source: String = "socket path") throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104 else {
            throw SimpleError("Invalid \(source): \(String(reflecting: path)) (\(path.utf8.count) UTF-8 bytes). Socket paths must be absolute, nonempty, contain no NUL, and be shorter than 104 UTF-8 bytes. Use --socket <absolute-path> or BROWSER_CLI_SOCKET to select a valid socket.")
        }
        return path
    }

    static func resolve(
        args: ParsedArgs,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemTempDirectory: () -> String? = CLISocketPath.systemUserTempDirectory
    ) throws -> String {
        try target(args: args, environment: environment, systemTempDirectory: systemTempDirectory).path
    }

    private static func target(
        args: ParsedArgs,
        environment: [String: String],
        systemTempDirectory: () -> String?
    ) throws -> (path: String, source: String) {
        let path: String
        let source: String
        if let explicit = args.flags["socket"] {
            path = explicit
            source = "--socket"
        } else if let inherited = environment["BROWSER_CLI_SOCKET"] {
            guard !inherited.isEmpty else {
                throw SimpleError("BROWSER_CLI_SOCKET is set but empty; unset it to use socket discovery, or pass --socket explicitly.")
            }
            guard args.flags["profiles-root"] == nil else {
                throw SimpleError("--profiles-root conflicts with inherited BROWSER_CLI_SOCKET. Unset BROWSER_CLI_SOCKET to discover that profiles root, or pass --socket explicitly to confirm the target.")
            }
            path = inherited
            source = "BROWSER_CLI_SOCKET"
        } else {
            let temp: String
            if let system = systemTempDirectory() {
                temp = system
                source = "system per-user temporary directory"
            } else if let fallback = environment["TMPDIR"], !fallback.isEmpty {
                temp = fallback
                source = "TMPDIR fallback after system lookup failed"
            } else {
                temp = "/tmp/"
                source = "/tmp fallback after system lookup failed"
            }
            let directory = DiskLocations.sessionAndProfilesMetadataDirectory(arguments: args.profilesRootArguments)
            path = CLISocketPath.path(inDirectory: directory, userTempDirectory: temp)
        }
        return (try validate(path, source: source), source)
    }

    static func send(_ request: CLIRequest, args: ParsedArgs) throws -> CLIResponse {
        let selected = try target(args: args, environment: ProcessInfo.processInfo.environment, systemTempDirectory: CLISocketPath.systemUserTempDirectory)
        do {
            return try SocketClient.send(request, socketPath: selected.path)
        } catch {
            throw SimpleError("\(error) Selected by \(selected.source).")
        }
    }

    /// Walk flags with the same arity as ArgParser so flag values remain opaque.
    static func parse(_ argv: [String]) throws -> ParsedArgs {
        var index = 0
        var seenTargets: Set<String> = []
        while index < argv.count {
            let token = argv[index]
            if token.hasPrefix("--socket"), token != "--socket" {
                throw SimpleError("Use two separate arguments: --socket <absolute-path>.")
            }
            if token.hasPrefix("--profiles-root"), token != "--profiles-root" {
                throw SimpleError("Use two separate arguments: --profiles-root <path>.")
            }
            if token == "--socket" || token == "--profiles-root" {
                guard seenTargets.insert(token).inserted else {
                    throw SimpleError("Repeated targeting flag \(token) is not allowed.")
                }
                guard index + 1 < argv.count, !argv[index + 1].isEmpty, !argv[index + 1].hasPrefix("--") else {
                    throw SimpleError("\(token) requires a value.")
                }
                if token == "--socket" { _ = try validate(argv[index + 1], source: "--socket") }
            }
            if token.hasPrefix("--"), token != "--json", token != "--help", !ArgParser.valuelessFlags.contains(String(token.dropFirst(2))) {
                index += 2
            } else {
                index += 1
            }
        }
        return ArgParser.parse(argv)
    }
}
