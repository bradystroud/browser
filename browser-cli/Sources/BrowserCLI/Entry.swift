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
        if let malformed = malformedProfilesRootArgument(in: argv) {
            FileHandle.standardError.write(Data("""
            Error: '\(malformed)' isn't how --profiles-root is spelled. Use two \
            separate arguments: --profiles-root <path>.

            Refusing to continue: an unrecognised --profiles-root silently falls \
            back to the real instance's own directory, so this command would have \
            targeted the running Browser rather than the scratch instance you meant.

            """.utf8))
            return false
        }

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
        case "windows":
            return WindowCommand.list(args: ArgParser.parse(Array(argv.dropFirst())))
        case "focus":
            return WindowCommand.focus(args: ArgParser.parse(Array(argv.dropFirst())))
        case "window":
            guard argv.count >= 2, argv[1] == "new" else {
                FileHandle.standardError.write(Data("usage: browser window new [<url>] [--profile <name>]\n".utf8))
                return false
            }
            return WindowCommand.new(args: ArgParser.parse(Array(argv.dropFirst(2))))
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

    /// `ProfilesRootResolver` only recognises the exact two-token pair
    /// `--profiles-root <path>`; anything else it doesn't understand it
    /// silently ignores, falling back to the real `~/Library/Application
    /// Support/Browser` instance. That fallback is the dangerous direction:
    /// a command an agent believed was scoped to a throwaway scratch
    /// instance instead opens tabs in, and creates profiles on, Brady's
    /// actual running browser -- which is exactly what happened while this
    /// command set was being tested, via zsh's (unlike bash's) *not*
    /// word-splitting an unquoted `$R` holding `--profiles-root /path`, so
    /// the whole thing arrived as one argument with a space in it.
    ///
    /// Any token that starts with `--profiles-root` but isn't exactly that
    /// is unambiguously a mis-spelled attempt at the flag -- including the
    /// `--profiles-root=/path` form, which this CLI's hand-rolled parser has
    /// never supported -- so it's a hard error rather than a silent
    /// retarget.
    static func malformedProfilesRootArgument(in argv: [String]) -> String? {
        argv.first { $0.hasPrefix("--profiles-root") && $0 != "--profiles-root" }
    }

    private static func printUsage() {
        print("""
        browser -- control a running Browser instance from the terminal

        Usage:
          browser open <url> [--profile <name>] [--new-window]
          browser window new [<url>] [--profile <name>]
          browser windows [--profile <name>]
          browser focus [<profile>] [--profile <name>]
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
