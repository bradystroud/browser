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
        guard let commandWord = argv.first else {
            printUsage()
            return false
        }

        switch commandWord {
        case "open":
            return OpenCommand.run(args: ArgParser.parse(Array(argv.dropFirst())))
        case "route-test":
            return RouteTestCommand.run(args: ArgParser.parse(Array(argv.dropFirst())))
        case "profiles":
            return ProfilesCommand.run(args: ArgParser.parse(Array(argv.dropFirst())))
        case "tabs":
            return TabsCommand.run(args: ArgParser.parse(Array(argv.dropFirst())))
        case "history":
            guard argv.count >= 2, argv[1] == "search" else {
                FileHandle.standardError.write(Data("usage: browser history search <query> [--limit N] [--profile <name>]\n".utf8))
                return false
            }
            return HistoryCommand.search(args: ArgParser.parse(Array(argv.dropFirst(2))))
        case "bookmarks":
            guard argv.count >= 2, argv[1] == "list" else {
                FileHandle.standardError.write(Data("usage: browser bookmarks list [--folder <path>] [--profile <name>]\n".utf8))
                return false
            }
            return BookmarksCommand.list(args: ArgParser.parse(Array(argv.dropFirst(2))))
        case "help", "--help", "-h":
            printUsage()
            return true
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
          browser open <url> [--profile <name>]
          browser route-test <url> [--from-app <bundle-id>]
          browser profiles
          browser tabs [--profile <name>]
          browser history search <query> [--limit N] [--profile <name>]
          browser bookmarks list [--folder <path>] [--profile <name>]

        Every command accepts --json for machine-readable output, and
        --profiles-root <path> to target a scratch instance instead of the
        real one (matches the app's own --profiles-root launch argument).
        """)
    }
}
