import Foundation

/// Everything parsed out of `CommandLine.arguments` (minus argv[0]): the
/// leading non-flag words (the command name, e.g. `["history", "search"]`,
/// plus any further positional arguments like a URL or search query),
/// `--flag value` pairs, and the bare `--json` switch. Deliberately
/// hand-rolled rather than a dependency (e.g. swift-argument-parser) --
/// the command surface is small and stable, and this keeps `swift build`
/// fully offline-capable with zero package resolution.
public struct ParsedArgs: Equatable {
    public let positionals: [String]
    public let flags: [String: String]
    public let jsonOutput: Bool

    public init(positionals: [String], flags: [String: String], jsonOutput: Bool) {
        self.positionals = positionals
        self.flags = flags
        self.jsonOutput = jsonOutput
    }
}

public enum ArgParser {
    /// Switches that never take a value. Every flag not listed here consumes
    /// the following token, so a bare switch missing from this set silently
    /// eats whatever came after it -- `browser open <url> --new-window
    /// --profile work` would parse `--profile` as `--new-window`'s value and
    /// then lose the profile entirely. Any new valueless flag must be added
    /// here.
    static let valuelessFlags: Set<String> = ["new-window", "little"]

    /// `--json` is a bare switch (no value), as is anything in
    /// `valuelessFlags` (recorded with an empty-string value -- callers test
    /// for presence, not the value). Every other `--name` consumes the
    /// following token as its value; a trailing `--name` with nothing after
    /// it gets an empty string rather than crashing or silently dropping the
    /// flag.
    public static func parse(_ args: [String]) -> ParsedArgs {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var json = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--json" {
                json = true
                index += 1
            } else if arg.hasPrefix("--"), valuelessFlags.contains(String(arg.dropFirst(2))) {
                flags[String(arg.dropFirst(2))] = ""
                index += 1
            } else if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if index + 1 < args.count {
                    flags[key] = args[index + 1]
                    index += 2
                } else {
                    flags[key] = ""
                    index += 1
                }
            } else {
                positionals.append(arg)
                index += 1
            }
        }
        return ParsedArgs(positionals: positionals, flags: flags, jsonOutput: json)
    }
}
