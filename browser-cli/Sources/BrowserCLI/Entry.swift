import Foundation

/// `browser` -- a companion CLI for controlling/inspecting a running
/// Browser instance from the terminal (browser-82d). Doubles as the
/// sanctioned way for agents to exercise the app without the
/// synthetic-input UI automation AGENTS.md already bans (osascript/System
/// Events/keystroke). See AGENTS.md's own "browser CLI" section for the
/// full command reference.
///
/// Deliberately, permanently has no command or field that surfaces
/// passwords/credentials, in any form, even behind `--json` -- this isn't a
/// gap to fill in later. Every command above (open/route-test/profiles/
/// tabs/history/bookmarks) only ever touches routing rules, profile
/// metadata, open-tab state, history, and bookmarks; keep it that way.
///
/// `@main` on a plain struct (not a `main.swift` top-level-code file)
/// deliberately -- it's what lets `BrowserCLITests` `@testable import
/// BrowserCLI` and exercise `ArgParser`/`RouteTestEngine` directly, which a
/// `main.swift`-shaped executable target can make awkward.
@main
struct BrowserCLIEntry {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        let succeeded = run(argv)
        exit(succeeded ? 0 : 1)
    }

    /// Split out from `main()` so it's callable from a test without
    /// touching the real process exit code.
    static func run(_ argv: [String]) -> Bool {
        let parsed: ParsedArgs
        do {
            parsed = try SocketTargetResolver.parse(argv)
        } catch {
            return Output.emitError("\(error)", json: ArgParser.parse(argv).jsonOutput)
        }
        if parsed.flags["version"] != nil {
            return VersionCommand.run(json: parsed.jsonOutput)
        }
        if parsed.flags["help"] != nil {
            if parsed.positionals.first == "page" { print(PageCommand.usage) }
            else { printUsage() }
            return true
        }
        guard let commandWord = parsed.positionals.first else {
            printUsage()
            return false
        }
        let args = parsed.droppingPositionals(1)
        if ["route-test", "history", "bookmarks"].contains(commandWord), args.flags["socket"] != nil {
            return Output.emitError("--socket applies only to socket commands", json: args.jsonOutput)
        }

        switch commandWord {
        case "socket-path":
            do {
                let path = try SocketTargetResolver.resolve(args: args)
                return Output.emit(["socketPath": path], json: args.jsonOutput) { $0["socketPath"] ?? "" }
            } catch {
                return Output.emitError("\(error)", json: args.jsonOutput)
            }
        case "open":
            return OpenCommand.run(args: args)
        case "route-test":
            return RouteTestCommand.run(args: args)
        case "profiles":
            return ProfilesCommand.run(args: args)
        case "tabs":
            return TabsCommand.run(args: args)
        case "windows":
            return WindowCommand.list(args: args)
        case "focus":
            return WindowCommand.focus(args: args)
        case "window":
            guard parsed.positionals.count >= 2, parsed.positionals[1] == "new" else {
                FileHandle.standardError.write(Data("usage: browser window new [<url>] [--profile <name>]\n".utf8))
                return false
            }
            return WindowCommand.new(args: args.droppingPositionals(1))
        case "page":
            return PageCommand.run(args: args)
        case "history":
            guard parsed.positionals.count >= 2, parsed.positionals[1] == "search" else {
                FileHandle.standardError.write(Data("usage: browser history search <query> [--limit N] [--profile <name>]\n".utf8))
                return false
            }
            return HistoryCommand.search(args: args.droppingPositionals(1))
        case "bookmarks":
            guard parsed.positionals.count >= 2, parsed.positionals[1] == "list" else {
                FileHandle.standardError.write(Data("usage: browser bookmarks list [--folder <path>] [--profile <name>]\n".utf8))
                return false
            }
            return BookmarksCommand.list(args: args.droppingPositionals(1))
        case "help", "--help", "-h":
            printUsage()
            return true
        case "-v", "version":
            return VersionCommand.run(json: parsed.jsonOutput)
        default:
            FileHandle.standardError.write(Data("Unknown command: \(commandWord)\n\n".utf8))
            printUsage()
            return false
        }
    }

    private static func printUsage() {
        print("""
        browser -- control a running Browser instance from the terminal

        Usage:
          browser socket-path [--json]
          browser open <url> [--profile <name>] [--new-window | --little]
          browser window new [<url>] [--profile <name>]
          browser windows [--profile <name>]
          browser focus [<profile>] [--profile <name>]
          browser route-test <url> [--from-app <bundle-id>]
          browser profiles
          browser tabs [--profile <name>]
          browser history search <query> [--limit N] [--profile <name>]
          browser bookmarks list [--folder <path>] [--profile <name>]
          browser page <subcommand> ...   (agent control; `browser page help`)
          browser --version               (the app version and the commit it was built from)

        Socket commands accept --socket <absolute-path> before or after the command.
        BROWSER_CLI_SOCKET supplies a default explicit socket.
        Every command accepts --json for machine-readable output, and
        --profiles-root <path> to target a scratch instance instead of the
        real one (matches the app's own --profiles-root launch argument).
        """)
    }
}
