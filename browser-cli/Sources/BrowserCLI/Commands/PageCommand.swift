import Foundation
import BrowserCLIProtocol

/// `browser page ...` -- lets an agent drive a window it opened itself, in a
/// chosen profile and signed in as that profile is: read it, click, type,
/// run a script, take screenshots and record it. Input goes to the page
/// inside the engine, never through the OS, so the real pointer and keyboard
/// focus are never touched and the app is never brought to the front.
///
/// Only windows opened by `page open` can be reached, and only while
/// Settings > Privacy > Agents is on in the running app. Typing into a
/// password field is refused, except a test password on a loopback origin
/// with `--allow-password`, and a snapshot never carries a password
/// field's value.
public enum PageCommand {
    static let usage = """
        browser page open [<url>] [--profile <name> | --private] [--viewport WxH | --width W --height H] [--cursor] [--headless] [--dialogs accept|dismiss]
                          [--allow-popups] [--opener <id> [--name N]]
                          [--wait-selector S] [--wait-text T] [--wait-js EXPR] [--wait-url U] [--wait-idle] [--timeout MS] [--no-wait]
        browser page resize <id> --viewport WxH
        browser page list
        browser page show <id> [--focus]   (bring a headless page on screen; only --focus gives it the keyboard)
        browser page hide <id>             (make it headless again)
        browser page navigate <id> <url> [--wait-... flags as for open]
        browser page reload <id> [--wait-... flags as for open]
        browser page wait <id> [--selector S] [--text T] [--js EXPR] [--url U] [--idle] [--gone] [--timeout MS]
        browser page snapshot <id> [--max-text N] [--max-elements N]
        browser page click <id> [<ref>] [--selector S] [--text T] [--role ROLE] [--double] [--wait-idle]
        browser page hover <id> [<ref>] [--selector S] [--text T] [--role ROLE]
        browser page type <id> <text> [--ref R | --selector S] [--text T] [--role ROLE] [--clear] [--delay MS] [--submit] [--allow-password] [--wait-idle]
        browser page press <id> <key> [--modifiers cmd,shift,alt,ctrl] [--allow-password] [--wait-idle]
        browser page select <id> <value> [--ref R | --selector S] [--text T] [--role ROLE]
        browser page upload <id> <file>... [--ref R | --selector S] [--text T]
        browser page dialogs <id> accept|dismiss [--prompt-text T]
        browser page popups <id> allow|block   (script-opened tabs, for every page in the window)
        browser page popup <id> <url> [--name N] [--wait-... flags as for open]   (open a page from <id>, as its window.open)
        browser page scroll <id> [--dy N] [--dx N] [--ref R | --selector S] [--text T]
        browser page eval <id> <code> [--raw]
        browser page screenshot <id> [--out <file.png>] [--full-page]
        browser page record start <id> [--out <dir>] [--quality N] [--cursor]
        browser page record stop <id>
        browser page close <id>

        Size: --viewport WxH sizes the page host in logical points, excluding browser chrome (200...8192 per
          dimension, at most 16777216 points total). --width/--height retain window-content sizing; supply both.
          resize preserves the page and session, and refuses while recording. JSON reports viewportWidth /
          viewportHeight measured as CSS innerWidth / innerHeight and zoomFactor. Page zoom affects these values.
          Explicit viewport pages keep native 1x capture for their lifetime; other pages keep display density.
        Targets: a ref from the last snapshot (e12), --selector (CSS), or --text (an element's name, matched
          case-insensitively; a link or button wins over plain text, a heading comes last). --selector with --text
          means both: the selector's matches whose name is (or else contains) the text. A ref is used alone.
          --role link|button|... narrows a selector or text match. The result says "(1 of N matches)" when the
          target was ambiguous.
        Passwords: type and press refuse a password field. --allow-password lets a test password in, only on a page
          served from this machine (localhost, *.localhost, 127.0.0.1, ::1); every other origin is still refused.
        Waiting: --wait-idle (on open/navigate/reload/click/type/press) and wait --idle return once no request is in
          flight and the DOM has not changed for 500 ms; --timeout MS caps every wait.
        eval: <code> is an expression (`document.title`), or statements run as an async function body
          (`const a = f(); return a.b`): with statements, only an explicit `return` gives a value. A returned promise
          is awaited. --raw prints a string result as plain text; everything else is JSON.
        Popups: a tab the page opens (window.open, a target=name or _blank link) becomes its own page, shown in `page
          list` with the page that opened it; the opener keeps its id. A click waits briefly for one; later ones are
          reported by the opener's next command. Without --allow-popups, WebKit refuses a window.open that runs well
          after the click (from a timer, or after an await); with it, a page may open tabs at any time. On WebKit a
          popup shares its opener's browsing-context group, so
          window.opener and named targets (target=name, window.open(url, name)) reach it; `page popup` and
          `page open --opener` open a page that way. CEF opens every popup as an unrelated tab with no opener and no
          name, and window.open returns null there, so a page that checks it takes its fallback.
        Time limit: every command stops with an error after --timeout MS plus 5 s, or 60 s when no --timeout is given.
        screenshot --full-page: on WebKit the page is scrolled and stitched, so content fixed to the viewport repeats.
        Agent strip: the window names the agent tool, its session name and model, found from Claude Code's or Codex's
          own session files. --agent NAME and --model ID (or BROWSER_AGENT_NAME / BROWSER_AGENT_MODEL) override them.
        """

    public static func run(argv: [String]) -> Bool {
        run(args: ArgParser.parse(argv))
    }

    public static func run(args parsed: ParsedArgs) -> Bool {
        let json = parsed.jsonOutput
        var positionals = parsed.positionals
        guard !positionals.isEmpty else { return usageError(json) }
        var sub = positionals.removeFirst()
        if sub == "help" {
            print(usage)
            return true
        }
        if sub == "record" {
            guard !positionals.isEmpty, ["start", "stop"].contains(positionals[0]) else { return usageError(json) }
            sub = "record-" + positionals.removeFirst()
        }

        var args: [String: String] = [:]
        let flags = parsed.flags
        func copy(_ flag: String, as key: String? = nil) {
            if let value = flags[flag] { args[key ?? flag] = value }
        }
        func bool(_ flag: String) {
            if flags[flag] != nil { args[flag] = "true" }
        }
        func target() {
            copy("ref")
            copy("selector")
            copy("text", as: "text-target")
            copy("role")
        }
        func waitFlags() {
            for name in ["wait-selector", "wait-text", "wait-js", "wait-url", "timeout"] { copy(name) }
            bool("no-wait")
            bool("wait-idle")
        }
        func takeId() -> Bool {
            guard !positionals.isEmpty else { return false }
            args["id"] = positionals.removeFirst()
            return true
        }

        switch sub {
        case "open":
            if let url = positionals.first { args["url"] = url }
            copy("profile")
            bool("private")
            bool("cursor")
            bool("headless")
            copy("dialogs")
            copy("viewport")
            copy("width")
            copy("height")
            bool("allow-popups")
            copy("opener")
            copy("name")
            waitFlags()
        case "resize":
            guard takeId(), positionals.isEmpty else { return usageError(json) }
            copy("viewport")
            copy("width")
            copy("height")
        case "popup":
            guard takeId(), let url = positionals.first else { return usageError(json) }
            args["url"] = url
            copy("name")
            waitFlags()
        case "popups":
            guard takeId(), let mode = positionals.first, ["allow", "block"].contains(mode) else { return usageError(json) }
            args["mode"] = mode
        case "list":
            break
        case "show", "hide":
            guard takeId() else { return usageError(json) }
            bool("focus")
        case "close", "snapshot", "record-stop":
            guard takeId() else { return usageError(json) }
            copy("max-text")
            copy("max-elements")
        case "navigate":
            guard takeId(), let url = positionals.first else { return usageError(json) }
            args["url"] = url
            waitFlags()
        case "reload":
            guard takeId() else { return usageError(json) }
            waitFlags()
        case "wait":
            guard takeId() else { return usageError(json) }
            copy("selector", as: "wait-selector")
            copy("text", as: "wait-text")
            copy("js", as: "wait-js")
            copy("url", as: "wait-url")
            copy("timeout")
            bool("gone")
            if flags["idle"] != nil { args["wait-idle"] = "true" }
        case "click", "hover":
            guard takeId() else { return usageError(json) }
            if let ref = positionals.first { args["ref"] = ref }
            target()
            bool("double")
            bool("wait-idle")
        case "type":
            guard takeId(), let text = positionals.first else { return usageError(json) }
            args["text"] = text
            target()
            copy("delay")
            bool("clear")
            bool("submit")
            bool("allow-password")
            bool("wait-idle")
        case "press":
            guard takeId(), let key = positionals.first else { return usageError(json) }
            args["key"] = key
            copy("modifiers")
            bool("allow-password")
            bool("wait-idle")
        case "select":
            guard takeId(), let value = positionals.first else { return usageError(json) }
            args["value"] = value
            target()
        case "upload":
            guard takeId(), !positionals.isEmpty else { return usageError(json) }
            args["files"] = positionals.map(absolutePath).joined(separator: "\n")
            target()
        case "dialogs":
            guard takeId(), let answer = positionals.first else { return usageError(json) }
            args["answer"] = answer
            copy("prompt-text")
        case "scroll":
            guard takeId() else { return usageError(json) }
            copy("dy")
            copy("dx")
            target()
        case "eval":
            guard takeId(), let expression = positionals.first else { return usageError(json) }
            args["expression"] = expression
        case "screenshot":
            guard takeId() else { return usageError(json) }
            args["path"] = absolutePath(flags["out"] ?? "page-\(args["id"]!)-\(timestamp()).png")
            bool("full-page")
        case "record-start":
            guard takeId() else { return usageError(json) }
            args["dir"] = absolutePath(flags["out"] ?? "recording-\(args["id"]!)-\(timestamp())")
            copy("quality")
            bool("cursor")
        default:
            return usageError(json)
        }

        if sub == "open" || sub == "resize" {
            do { _ = try CLIPageSize.parse(args, requiresViewport: sub == "resize") }
            catch { return Output.emitError(error.localizedDescription, json: json) }
        }

        if sub != "list" {
            args.merge(AgentIdentity.detect(flags: flags).requestArgs) { current, _ in current }
        }

        do {
            let response = try SocketTargetResolver.send(CLIRequest(command: "page-" + sub, args: args), args: parsed)
            guard response.ok else {
                if json { return Output.emitError(response.error ?? "page \(sub) failed", json: true) }
                return Output.emitError(response.error ?? "page \(sub) failed", json: false)
            }
            if let error = viewportCompatibilityError(response, requested: args["viewport"] != nil) {
                return Output.emitError(error, json: json)
            }
            if sub == "eval", !json, flags["raw"] != nil, case .string(let text)? = response.value {
                print(text)
                return true
            }
            return Output.emit(response, json: json, text: render)
        } catch {
            return Output.emitError("\(error)", json: json)
        }
    }

    static func viewportCompatibilityError(_ response: CLIResponse, requested: Bool) -> String? {
        // The same app version introduced zoom metadata and explicit viewport sizing.
        // A current app may omit only the dimensions when the renderer cannot answer in time.
        guard requested, response.page?.zoomFactor == nil else { return nil }
        guard let page = response.page, page.viewportWidth != nil, page.viewportHeight != nil else {
            return "Browser did not report the requested viewport for \(response.page?.id ?? "the page"). Update Browser if it is older, or retry after the page has loaded."
        }
        return nil
    }

    private static func usageError(_ json: Bool) -> Bool {
        Output.emitError("usage:\n\(usage)", json: json)
    }

    static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func render(_ response: CLIResponse) -> String {
        if let snapshot = response.snapshot {
            var lines = ["\(snapshot.title)", snapshot.url, "", "Elements:"]
            for element in snapshot.elements {
                var line = "  \(element.ref) \(element.role)"
                if !element.name.isEmpty { line += " \"\(element.name)\"" }
                if let value = element.value, !value.isEmpty { line += " value=\"\(value)\"" }
                if let title = element.title { line += " title=\"\(title)\"" }
                if let shortcut = element.shortcut { line += " shortcut=\"\(shortcut)\"" }
                if element.type == "password" { line += " [password]" }
                if let checked = element.checked { line += checked ? " [checked]" : " [unchecked]" }
                if element.disabled == true { line += " [disabled]" }
                if !element.inViewport { line += " [offscreen]" }
                lines.append(line)
            }
            if snapshot.elementsTruncated { lines.append("  … more elements; pass --max-elements") }
            lines += ["", "Text:", snapshot.text]
            if snapshot.textTruncated { lines.append("… text truncated; pass --max-text") }
            return lines.joined(separator: "\n")
        }
        if let pages = response.pages {
            guard !pages.isEmpty else { return "(no agent pages)" }
            return pages.map { "\($0.id)\t\($0.isPrivate ? "private" : $0.profileName)\t\($0.isHeadless == true ? "headless" : "headed")\t\($0.engine ?? "")\t\($0.openedBy.map { "opened by \($0)" } ?? "")\t\($0.title)\t\($0.url)\t\(viewportDescription($0))" }.joined(separator: "\n")
        }
        let message = response.message ?? "OK"
        if let page = response.page, page.viewportWidth != nil, page.viewportHeight != nil {
            return message + " Viewport: " + viewportDescription(page) + "."
        }
        return message
    }

    private static func viewportDescription(_ page: CLIPageInfo) -> String {
        guard let width = page.viewportWidth, let height = page.viewportHeight else { return "viewport unavailable" }
        return "\(Int(width))x\(Int(height))"
    }
}
