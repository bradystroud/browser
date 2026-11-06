import AppKit

/// Whether the `browser page` commands work at all. Off by default: with it
/// on, any program running as this user can open a window in a signed-in
/// profile and act in it. The CLI can never turn it on -- only Settings, or
/// `--allow-agent-control` on the app's own command line.
enum AgentControlPreference {
    private static let key = "AgentControlEnabled"

    static var isEnabledInSettings: Bool {
        get { AppPreferencesStore.current.bool(forKey: key) }
        set { AppPreferencesStore.current.set(newValue, forKey: key) }
    }

    static var isEnabled: Bool {
        isEnabledInSettings || CommandLine.arguments.contains("--allow-agent-control")
    }
}

/// One window an agent opened with `browser page open`. Commands act on its
/// visible tab, so a page that opens a link in a new tab of the same window
/// is followed there.
final class AgentPage {
    let id: String
    weak var controller: BrowserWindowController?
    /// Draw a pointer where synthetic clicks land, for recordings: the
    /// engine's own input has no visible pointer.
    var showsCursor = false
    var recorder: AgentRecorder?
    /// How a confirm() or prompt() is answered. An alert has only OK.
    var acceptsDialogs = false
    var promptText: String?
    /// Files the next file chooser gets, set by `page upload`.
    var uploadFiles: [URL] = []
    /// What the page did on its own since the last command reported it:
    /// dialogs answered and file choosers opened.
    var events: [String] = []

    init(id: String, controller: BrowserWindowController) {
        self.id = id
        self.controller = controller
    }

    var tab: Tab? { controller?.activeTab }

    /// The visible tab's automation, set to answer the page's dialogs here
    /// rather than show them: a dialog left open blocks the page, and every
    /// command after it would wait.
    var automation: EngineTabAutomation? {
        guard let automation = tab?.browser?.automation else { return nil }
        if automation.dialogHandler == nil {
            automation.dialogHandler = { [weak self] dialog in self?.answer(dialog) ?? .dismiss }
        }
        return automation
    }

    private func answer(_ dialog: EngineAutomationDialog) -> EngineAutomationDialogAnswer {
        let verdict = acceptsDialogs ? "accepted" : "dismissed"
        switch dialog {
        case .alert(let message):
            events.append("alert \"\(message)\" (closed)")
            return .accept(text: nil)
        case .confirm(let message):
            events.append("confirm \"\(message)\" (\(verdict); `browser page dialogs \(id) \(acceptsDialogs ? "dismiss" : "accept")` changes this)")
            return acceptsDialogs ? .accept(text: nil) : .dismiss
        case .prompt(let message, let defaultText):
            let text = promptText ?? defaultText ?? ""
            events.append("prompt \"\(message)\" (\(acceptsDialogs ? "answered \"\(text)\"" : verdict))")
            return acceptsDialogs ? .accept(text: text) : .dismiss
        case .fileChooser(let allowsMultiple, _):
            guard !uploadFiles.isEmpty else {
                events.append("file chooser opened and was cancelled; `browser page upload` gives it files")
                return .dismiss
            }
            let files = allowsMultiple ? uploadFiles : Array(uploadFiles.prefix(1))
            uploadFiles = []
            events.append("file chooser given \(files.map(\.lastPathComponent).joined(separator: ", "))")
            return .files(files)
        }
    }
}

/// The `page-*` commands of CLIServer. Every one reaches only windows in
/// `pages` -- windows an agent opened here -- never the user's own.
/// Everything runs on the main thread, and `completion` is called exactly
/// once.
enum AgentPages {
    private static var pages: [String: AgentPage] = [:]
    private static var nextNumber = 1

    private static let defaultOpenTimeout: TimeInterval = 30
    private static let defaultWaitTimeout: TimeInterval = 15
    private static let pollInterval: TimeInterval = 0.1
    /// Long enough for the drawn cursor's own move transition to finish.
    private static let cursorMoveDelay: TimeInterval = 0.45

    /// Whether `tab` is in a window an agent controls. The password manager
    /// never fills one.
    static func controls(_ tab: Tab) -> Bool {
        pages.values.contains { $0.controller?.tabs.contains { $0 === tab } ?? false }
    }

    typealias Completion = (CLIResponse) -> Void

    static func handle(_ request: CLIRequest, completion: @escaping Completion) {
        guard AgentControlPreference.isEnabled else {
            return completion(.failure(
                "Agent control is off. Turn on Settings > Privacy > Agents in Browser (or launch it with --allow-agent-control)."))
        }
        guard Engines.anyEngine({ $0.agentControl }) else {
            return completion(.failure("No engine here has agent control."))
        }
        prune()
        let args = request.args
        switch request.command {
        case "page-open": open(args, completion: completion)
        case "page-list": completion(CLIResponse(ok: true, message: "\(pages.count) page(s)", pages: pages.values.sorted { $0.id < $1.id }.map(info)))
        default:
            guard let id = args["id"], !id.isEmpty else { return completion(.failure("\(request.command) requires a page id")) }
            guard let page = pages[id], page.controller != nil else {
                return completion(.failure("No agent page \(id). `browser page list` shows the open ones; only pages opened with `browser page open` can be controlled."))
            }
            let completion = reporting(page, completion)
            page.controller?.agentIndicator?.update(activity: activityDescription(request))
            switch request.command {
            case "page-close": close(page, completion: completion)
            case "page-show", "page-hide":
                let headless = request.command == "page-hide"
                page.controller?.present(headless ? .headless : .headed)
                completion(CLIResponse(ok: true, message: headless ? "\(page.id) is headless." : "\(page.id) is on screen. It did not take focus.", page: info(page)))
            case "page-navigate": navigate(page, args, completion: completion)
            case "page-wait": wait(page, args, defaultTimeout: defaultWaitTimeout, completion: completion)
            case "page-snapshot": snapshot(page, args, completion: completion)
            case "page-click": click(page, args, completion: completion)
            case "page-hover": hover(page, args, completion: completion)
            case "page-type": type(page, args, completion: completion)
            case "page-press": press(page, args, completion: completion)
            case "page-dialogs": setDialogs(page, args, completion: completion)
            case "page-upload": upload(page, args, completion: completion)
            case "page-select": select(page, args, completion: completion)
            case "page-scroll": scroll(page, args, completion: completion)
            case "page-eval": evaluate(page, args, completion: completion)
            case "page-screenshot": screenshot(page, args, completion: completion)
            case "page-record-start": startRecording(page, args, completion: completion)
            case "page-record-stop": stopRecording(page, completion: completion)
            default: completion(.failure("unknown command: \(request.command)"))
            }
        }
    }

    // MARK: - Pages

    /// What the agent window's strip shows for a command: its name and
    /// target, never typed text or a script, which may be private.
    private static func activityDescription(_ request: CLIRequest) -> String {
        let name = request.command.hasPrefix("page-") ? String(request.command.dropFirst(5)) : request.command
        let args = request.args
        switch request.command {
        case "page-click", "page-hover", "page-type", "page-select", "page-upload":
            let target = [args["ref"], args["selector"], args["text-target"].map { "\"\($0.prefix(40))\"" }]
                .compactMap { $0 }.first { !$0.isEmpty }
            return [name, target].compactMap { $0 }.joined(separator: " ")
        case "page-press":
            return [name, args["key"]].compactMap { $0 }.joined(separator: " ")
        case "page-navigate":
            let host = args["url"].flatMap { URL(string: $0)?.host }
            return [name, host].compactMap { $0 }.joined(separator: " ")
        default:
            return name.replacingOccurrences(of: "-", with: " ")
        }
    }

    /// Adds what the page did on its own during the command to its result.
    private static func reporting(_ page: AgentPage, _ completion: @escaping Completion) -> Completion {
        { response in
            guard !page.events.isEmpty else { return completion(response) }
            var response = response
            response.pageEvents = page.events
            let lines = page.events.map { "Page: \($0)" }.joined(separator: "\n")
            page.events = []
            if response.ok {
                response.message = [response.message, lines].compactMap { $0 }.joined(separator: "\n")
            } else {
                response.error = [response.error, lines].compactMap { $0 }.joined(separator: "\n")
            }
            completion(response)
        }
    }

    private static func prune() {
        for (id, page) in pages {
            guard let controller = page.controller, WindowManager.shared.windowControllers.contains(where: { $0 === controller }) else {
                page.recorder?.cancel()
                pages[id] = nil
                continue
            }
        }
    }

    private static func info(_ page: AgentPage) -> CLIPageInfo {
        let tab = page.tab
        let url = tab.map { $0.urlString.isEmpty ? "about:blank" : $0.urlString } ?? ""
        return CLIPageInfo(
            id: page.id,
            profileName: page.controller?.profile.name ?? "",
            isPrivate: page.controller?.isPrivate ?? false,
            url: url,
            title: tab?.title ?? "",
            isLoading: tab?.isLoading ?? false,
            isHeadless: page.controller?.agentPresentation == .headless,
            engine: tab?.engine.rawValue)
    }

    private static func open(_ args: [String: String], completion: @escaping Completion) {
        let url = args["url"].flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        let profile: Profile
        let isPrivate = args["private"] == "true"
        if isPrivate {
            profile = Profile(id: "\(Profile.privateIdPrefix)\(UUID().uuidString)", name: "Private", colorHex: "#3a3a3c")
        } else if let name = args["profile"] {
            guard let named = ProfileManager.shared.profile(named: name) else {
                let names = ProfileManager.shared.profiles.map(\.name).joined(separator: ", ")
                return completion(.failure("No profile named '\(name)'. Profiles: \(names)."))
            }
            profile = named
        } else {
            profile = ProfileManager.shared.fallbackProfile
        }

        let controller = WindowManager.shared.openNewWindow(
            profile: profile, initialURL: url, isPrivate: isPrivate, activateApp: false,
            agentPresentation: args["headless"] == "true" ? .headless : .headed)
        if let width = args["width"].flatMap(Double.init), let height = args["height"].flatMap(Double.init),
           width >= 200, height >= 200 {
            controller.window?.setContentSize(NSSize(width: width, height: height))
        }

        let page = AgentPage(id: "p\(nextNumber)", controller: controller)
        nextNumber += 1
        controller.agentIndicator?.update(pageId: page.id)
        page.showsCursor = args["cursor"] == "true"
        page.acceptsDialogs = args["dialogs"] == "accept"
        pages[page.id] = page
        page.automation?.prepare { _ in }
        let completion = reporting(page, completion)

        guard args["no-wait"] != "true" else {
            return completion(CLIResponse(ok: true, message: "Opened \(page.id) in profile '\(profile.name)'.", page: info(page)))
        }
        wait(page, args, defaultTimeout: defaultOpenTimeout) { response in
            guard response.ok else {
                return completion(CLIResponse(ok: false, error: "Opened \(page.id), but: \(response.error ?? "the wait failed")", page: info(page)))
            }
            completion(CLIResponse(ok: true, message: "Opened \(page.id) in profile '\(profile.name)': \(info(page).url)", page: info(page)))
        }
    }

    private static func close(_ page: AgentPage, completion: @escaping Completion) {
        page.recorder?.cancel()
        page.recorder = nil
        pages[page.id] = nil
        page.controller?.window?.close()
        completion(CLIResponse(ok: true, message: "Closed \(page.id)."))
    }

    private static func navigate(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let url = args["url"], !url.isEmpty, let tab = page.tab else { return completion(.failure("navigate requires a url")) }
        tab.load(url: url)
        guard args["no-wait"] != "true" else { return completion(CLIResponse(ok: true, message: "Loading \(url).", page: info(page))) }
        // The old document is still there for a moment; let the load start
        // before the first poll can see it as complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            wait(page, args, defaultTimeout: defaultOpenTimeout, completion: completion)
        }
    }

    // MARK: - Engine access

    /// The page's tab automation, made ready to act (focus emulated) first.
    private static func automation(
        _ page: AgentPage,
        completion: @escaping Completion,
        then body: @escaping (EngineTabAutomation) -> Void
    ) {
        guard let tab = page.tab else { return completion(.failure("\(page.id) has no tab")) }
        // Per tab: the page's engine was picked by the engine rules when it
        // opened, and an agent's tab stays in it (Tab.holdsEngine).
        guard tab.capabilities.agentControl else {
            return completion(.failure("\(page.id)'s engine (\(tab.engine.rawValue)) has no agent control"))
        }
        guard let automation = page.automation else {
            return completion(.failure("\(page.id)'s tab has no live page yet"))
        }
        automation.prepare { result in
            if case .failure(let error) = result { return completion(.failure(error.message)) }
            body(automation)
        }
    }

    private static func run(
        _ automation: EngineTabAutomation,
        _ body: String,
        completion: @escaping Completion,
        then: @escaping (Any?) -> Void
    ) {
        automation.evaluate(AgentPageScript.call(body)) { result in
            switch result {
            case .failure(let error): completion(.failure(pageError(error)))
            case .success(let value): then(value)
            }
        }
    }

    /// A script error as the page threw it, without the engine's own
    /// "Error: " prefix: the CLI adds its own.
    private static func pageError(_ error: EngineAutomationError) -> String {
        error.message.hasPrefix("Error: ") ? String(error.message.dropFirst(7)) : error.message
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value) || value is [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func targetLiteral(_ args: [String: String]) -> String? {
        let ref = args["ref"].flatMap { $0.isEmpty ? nil : $0 }
        let selector = args["selector"].flatMap { $0.isEmpty ? nil : $0 }
        let text = args["text-target"].flatMap { $0.isEmpty ? nil : $0 }
        guard ref != nil || selector != nil || text != nil else { return nil }
        return AgentPageScript.target(ref: ref, selector: selector, text: text)
    }

    private struct TargetPoint: Decodable {
        let x: Double
        let y: Double
        let obscured: Bool
        let password: Bool
        let element: CLIPageElement
    }

    /// Scrolls the target into view and finds where to click it.
    private static func locate(
        _ automation: EngineTabAutomation,
        _ target: String,
        completion: @escaping Completion,
        then: @escaping (TargetPoint) -> Void
    ) {
        run(automation, "return A.point(A.resolve(\(target)));", completion: completion) { value in
            guard let point = decode(TargetPoint.self, value) else { return completion(.failure("could not locate the target")) }
            then(point)
        }
    }

    /// Moves the drawn cursor first when the page shows one, so a recording
    /// sees the pointer travel before the click lands.
    private static func moveCursor(
        _ page: AgentPage,
        _ automation: EngineTabAutomation,
        to point: TargetPoint,
        then: @escaping () -> Void
    ) {
        guard page.showsCursor else { return then() }
        automation.evaluate(AgentPageScript.call("A.cursor(\(point.x), \(point.y), false); return true;")) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + cursorMoveDelay, execute: then)
        }
    }

    private static func pressCursor(_ page: AgentPage, _ automation: EngineTabAutomation, at point: TargetPoint) {
        guard page.showsCursor else { return }
        automation.evaluate(AgentPageScript.call("A.cursor(\(point.x), \(point.y), true); setTimeout(() => A.cursor(\(point.x), \(point.y), false), 150); return true;")) { _ in }
    }

    // MARK: - Reading

    private static func snapshot(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        let maxText = args["max-text"].flatMap(Int.init) ?? 20000
        let maxElements = args["max-elements"].flatMap(Int.init) ?? 800
        automation(page, completion: completion) { automation in
            run(automation, "return A.snapshot(\(maxText), \(maxElements));", completion: completion) { value in
                guard let snapshot = decode(CLIPageSnapshot.self, value) else {
                    return completion(.failure("the page returned an unreadable snapshot"))
                }
                completion(CLIResponse(
                    ok: true,
                    message: "\(snapshot.elements.count) element(s)",
                    page: info(page),
                    snapshot: snapshot))
            }
        }
    }

    private static func evaluate(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let expression = args["expression"], !expression.isEmpty else { return completion(.failure("eval requires an expression")) }
        automation(page, completion: completion) { automation in
            automation.evaluate(jsonSafe(expression)) { result in
                switch result {
                case .failure(let error): completion(.failure(pageError(error)))
                case .success(let value):
                    let json = CLIJSONValue(foundation: value)
                    completion(CLIResponse(ok: true, message: render(json), value: json))
                }
            }
        }
    }

    /// `expression`, with a value JSON cannot carry made into one it can:
    /// an element becomes its HTML (cut short), a function its source, and
    /// a cycle "[Circular]".
    private static func jsonSafe(_ expression: String) -> String {
        """
        (async () => {
          const value = await (
        \(expression)
          );
          const seen = new WeakSet();
          const node = (n) => {
            const html = n.outerHTML ?? n.textContent ?? n.nodeName;
            return html.length > 2000 ? html.slice(0, 1999) + '…' : html;
          };
          const replace = (key, v) => {
            if (typeof v === 'function') return String(v);
            if (typeof v === 'bigint') return v.toString();
            if (typeof Node !== 'undefined' && v instanceof Node) return node(v);
            if (v && typeof v === 'object') {
              if (seen.has(v)) return '[Circular]';
              seen.add(v);
            }
            return v;
          };
          const text = JSON.stringify(value, replace);
          return text === undefined ? null : JSON.parse(text);
        })()
        """
    }

    private static func render(_ value: CLIJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Waiting

    private enum Condition {
        case loaded
        case selector(String, gone: Bool)
        case text(String, gone: Bool)
        case script(String)
        case urlContains(String)
    }

    /// Waits for the page to finish loading, then for every condition in
    /// `args` at once: `selector`, `text`, `js` (truthy), `url` (contains),
    /// with `gone` turning the selector/text ones into "until it is gone".
    private static func wait(_ page: AgentPage, _ args: [String: String], defaultTimeout: TimeInterval, completion: @escaping Completion) {
        let gone = args["gone"] == "true"
        var conditions: [Condition] = [.loaded]
        if let selector = args["wait-selector"], !selector.isEmpty { conditions.append(.selector(selector, gone: gone)) }
        if let text = args["wait-text"], !text.isEmpty { conditions.append(.text(text, gone: gone)) }
        if let script = args["wait-js"], !script.isEmpty { conditions.append(.script(script)) }
        if let url = args["wait-url"], !url.isEmpty { conditions.append(.urlContains(url)) }
        let timeout = args["timeout"].flatMap(Double.init).map { $0 / 1000 } ?? defaultTimeout
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            guard page.controller != nil else { return completion(.failure("\(page.id) closed")) }
            check(page, conditions[...]) { met in
                if met {
                    return completion(CLIResponse(ok: true, message: "Ready: \(info(page).url)", page: info(page)))
                }
                guard Date() < deadline else {
                    let waits = conditions.map(describe).joined(separator: ", ")
                    return completion(CLIResponse(ok: false, error: "Timed out after \(Int(timeout * 1000)) ms waiting on \(page.id) for \(waits). It is at \(info(page).url).", page: info(page)))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
            }
        }
        poll()
    }

    private static func describe(_ condition: Condition) -> String {
        switch condition {
        case .loaded: return "the page to load"
        case .selector(let selector, let gone): return "selector \(selector) \(gone ? "to go" : "to show")"
        case .text(let text, let gone): return "text \"\(text)\" \(gone ? "to go" : "to show")"
        case .script(let script): return "\(script) to be true"
        case .urlContains(let fragment): return "a URL with \(fragment)"
        }
    }

    private static func check(_ page: AgentPage, _ conditions: ArraySlice<Condition>, completion: @escaping (Bool) -> Void) {
        guard let condition = conditions.first else { return completion(true) }
        guard let tab = page.tab, let automation = page.automation else { return completion(false) }
        let next = { (met: Bool) in
            met ? check(page, conditions.dropFirst(), completion: completion) : completion(false)
        }
        // An error here is usually a document being replaced mid-poll: not
        // met yet, try again.
        let ask = { (body: String) in
            automation.evaluate(AgentPageScript.call(body)) { result in
                if case .success(let value) = result { next((value as? Bool) == true) } else { next(false) }
            }
        }
        switch condition {
        case .loaded:
            guard !tab.isLoading else { return completion(false) }
            // A WebKit tab can sit on its first, empty about:blank document,
            // complete and not loading, before its real load starts. That is
            // only "loaded" when about:blank is what was asked for.
            let wantsBlank = tab.urlString.isEmpty || tab.urlString == "about:blank"
            ask("return document.readyState === 'complete' && (\(wantsBlank) || location.href !== 'about:blank');")
        case .selector(let selector, let gone):
            ask("return A.has(\(AgentPageScript.literal(selector)), null) !== \(gone);")
        case .text(let text, let gone):
            ask("return A.has(null, \(AgentPageScript.literal(text))) !== \(gone);")
        case .script(let script):
            ask("return !!(await (async () => (\(script)))());")
        case .urlContains(let fragment):
            next(tab.urlString.contains(fragment))
        }
    }

    // MARK: - Acting

    private static func click(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let target = targetLiteral(args) else { return completion(.failure("click requires a ref, --selector or --text")) }
        automation(page, completion: completion) { automation in
            locate(automation, target, completion: completion) { point in
                moveCursor(page, automation, to: point) {
                    pressCursor(page, automation, at: point)
                    automation.click(at: CGPoint(x: point.x, y: point.y), clickCount: args["double"] == "true" ? 2 : 1) { result in
                        if case .failure(let error) = result { return completion(.failure(error.message)) }
                        let note = point.obscured ? " (another element covers its centre, which got the click)" : ""
                        completion(CLIResponse(ok: true, message: "Clicked \(describe(point.element))\(note).", element: point.element))
                    }
                }
            }
        }
    }

    private static func hover(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let target = targetLiteral(args) else { return completion(.failure("hover requires a ref, --selector or --text")) }
        automation(page, completion: completion) { automation in
            locate(automation, target, completion: completion) { point in
                moveCursor(page, automation, to: point) {
                    automation.mouseMove(to: CGPoint(x: point.x, y: point.y)) { result in
                        if case .failure(let error) = result { return completion(.failure(error.message)) }
                        completion(CLIResponse(ok: true, message: "Hovering \(describe(point.element)).", element: point.element))
                    }
                }
            }
        }
    }

    private struct FocusState: Decodable {
        let password: Bool
        let element: CLIPageElement?
    }

    private static let passwordRefusal = "Refused: the focused field is a password field. Agents never type into password fields."

    private static func focusState(_ automation: EngineTabAutomation, completion: @escaping Completion, then: @escaping (FocusState) -> Void) {
        run(automation, """
            const el = A.deepActive();
            return {password: A.isPassword(el), element: el && el !== document.body && el !== document.documentElement ? A.describe(el) : null};
            """, completion: completion) { value in
            guard let state = decode(FocusState.self, value) else { return completion(.failure("could not read the focused element")) }
            then(state)
        }
    }

    private static func type(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let text = args["text"] else { return completion(.failure("type requires text")) }
        let delay = (args["delay"].flatMap(Double.init) ?? 0) / 1000
        automation(page, completion: completion) { automation in
            let typeIntoFocus = {
                focusState(automation, completion: completion) { state in
                    guard !state.password else { return completion(.failure(passwordRefusal)) }
                    let afterClear = {
                        insert(text, into: automation, delay: delay) { result in
                            if case .failure(let error) = result { return completion(.failure(error.message)) }
                            let done = {
                                completion(CLIResponse(ok: true, message: "Typed \(text.count) character(s)\(state.element.map { " into \(describe($0))" } ?? "").", element: state.element))
                            }
                            guard args["submit"] == "true", let enter = EngineAutomationKey(name: "Enter") else { return done() }
                            automation.pressKey(enter, modifiers: []) { _ in done() }
                        }
                    }
                    guard args["clear"] == "true" else { return afterClear() }
                    run(automation, """
                        const el = A.deepActive();
                        if (el && typeof el.select === 'function') el.select(); else (el ? el.ownerDocument : document).execCommand('selectAll');
                        return true;
                        """, completion: completion) { _ in
                        guard text.isEmpty, let backspace = EngineAutomationKey(name: "Backspace") else { return afterClear() }
                        automation.pressKey(backspace, modifiers: []) { _ in afterClear() }
                    }
                }
            }
            guard let target = targetLiteral(args) else { return typeIntoFocus() }
            locate(automation, target, completion: completion) { point in
                guard !point.password else { return completion(.failure(passwordRefusal)) }
                moveCursor(page, automation, to: point) {
                    pressCursor(page, automation, at: point)
                    automation.click(at: CGPoint(x: point.x, y: point.y), clickCount: 1) { result in
                        if case .failure(let error) = result { return completion(.failure(error.message)) }
                        typeIntoFocus()
                    }
                }
            }
        }
    }

    /// The whole string at once, or one character at a time `delay` apart,
    /// which is what a recording of someone typing looks like.
    private static func insert(
        _ text: String,
        into automation: EngineTabAutomation,
        delay: TimeInterval,
        completion: @escaping (Result<Void, EngineAutomationError>) -> Void
    ) {
        guard delay > 0, text.count > 1 else {
            return text.isEmpty ? completion(.success(())) : automation.insertText(text, completion: completion)
        }
        var remaining = Substring(text)
        func next() {
            guard let character = remaining.first else { return completion(.success(())) }
            remaining = remaining.dropFirst()
            automation.insertText(String(character)) { result in
                if case .failure = result { return completion(result) }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
            }
        }
        next()
    }

    private static func press(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let name = args["key"], let key = EngineAutomationKey(name: name) else {
            return completion(.failure("press requires a key: Enter, Escape, Tab, Backspace, Delete, Space, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, or one character"))
        }
        var modifiers: EngineAutomationModifiers = []
        for part in (args["modifiers"] ?? "").lowercased().split(separator: ",") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.alt)
            case "shift": modifiers.insert(.shift)
            default: return completion(.failure("unknown modifier '\(part)'"))
            }
        }
        automation(page, completion: completion) { automation in
            focusState(automation, completion: completion) { state in
                // Named keys only move or submit; a character would type.
                guard !(state.password && key.text != nil && key.key != "Enter") else { return completion(.failure(passwordRefusal)) }
                automation.pressKey(key, modifiers: modifiers) { result in
                    if case .failure(let error) = result { return completion(.failure(error.message)) }
                    completion(CLIResponse(ok: true, message: "Pressed \(name)."))
                }
            }
        }
    }

    private static func setDialogs(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        switch args["answer"] {
        case "accept": page.acceptsDialogs = true
        case "dismiss": page.acceptsDialogs = false
        default: return completion(.failure("dialogs takes accept or dismiss"))
        }
        if let text = args["prompt-text"] { page.promptText = text }
        completion(CLIResponse(ok: true, message: "\(page.id) now \(page.acceptsDialogs ? "accepts" : "dismisses") confirm() and prompt() dialogs."))
    }

    /// The app's own data (every profile's cookies, saved passwords and
    /// history) and the login keychains never go to a page.
    private static func isPrivateToTheApp(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let refused = [
            CommandLineArgs.profilesRootPath(),
            CommandLineArgs.sessionAndProfilesMetadataDirectory(),
            home.appendingPathComponent("Library/Keychains").path,
        ].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        let path = url.resolvingSymlinksInPath().path
        return refused.contains { path.hasPrefix($0) }
    }

    /// Clicks the target with `files` ready for the file chooser it opens.
    private static func upload(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        let paths = (args["files"] ?? "").split(separator: "\n").map(String.init)
        guard !paths.isEmpty else { return completion(.failure("upload requires at least one file")) }
        guard targetLiteral(args) != nil else { return completion(.failure("upload requires the ref, --selector or --text of what opens the file chooser")) }
        var files: [URL] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else {
                return completion(.failure("\(path) is not a readable file (give an absolute path)"))
            }
            let url = URL(fileURLWithPath: path)
            guard !isPrivateToTheApp(url) else { return completion(.failure("Refused: \(path) is the browser's own data or a keychain.")) }
            files.append(url)
        }
        page.uploadFiles = files
        click(page, args) { response in
            // The chooser asks while the click is handled; give it a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard response.ok else {
                    page.uploadFiles = []
                    return completion(response)
                }
                guard page.uploadFiles.isEmpty else {
                    page.uploadFiles = []
                    return completion(CLIResponse(ok: false, error: "The click opened no file chooser. Target the file input itself, or the button that opens it.", element: response.element))
                }
                completion(response)
            }
        }
    }

    private static func select(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let target = targetLiteral(args), let value = args["value"] else {
            return completion(.failure("select requires a target and a value"))
        }
        automation(page, completion: completion) { automation in
            run(automation, """
                const el = A.resolve(\(target));
                if (el.tagName !== 'SELECT') throw new Error('not a <select>: click it, then click the option in the list it shows');
                const want = \(AgentPageScript.literal(value));
                const options = Array.from(el.options);
                const option = options.find(o => o.value === want) || options.find(o => o.text.trim().toLowerCase() === want.toLowerCase());
                if (!option) throw new Error('no option ' + want + '; options: ' + options.map(o => o.text.trim()).join(', '));
                el.value = option.value;
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                return A.describe(el);
                """, completion: completion) { result in
                let element = decode(CLIPageElement.self, result)
                completion(CLIResponse(ok: true, message: "Selected \(value).", element: element))
            }
        }
    }

    private static func scroll(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        automation(page, completion: completion) { automation in
            if let target = targetLiteral(args) {
                return locate(automation, target, completion: completion) { point in
                    completion(CLIResponse(ok: true, message: "Scrolled \(describe(point.element)) into view.", element: point.element))
                }
            }
            let deltaY = args["dy"].flatMap(Double.init) ?? 600
            let deltaX = args["dx"].flatMap(Double.init) ?? 0
            run(automation, "return [innerWidth / 2, innerHeight / 2];", completion: completion) { value in
                let centre = value as? [Double] ?? [400, 300]
                automation.scroll(at: CGPoint(x: centre[0], y: centre[1]), deltaX: deltaX, deltaY: deltaY) { result in
                    if case .failure(let error) = result { return completion(.failure(error.message)) }
                    completion(CLIResponse(ok: true, message: "Scrolled by \(Int(deltaY)) px."))
                }
            }
        }
    }

    private static func describe(_ element: CLIPageElement) -> String {
        element.name.isEmpty ? "\(element.ref) (\(element.role))" : "\(element.ref) \(element.role) \"\(element.name)\""
    }

    // MARK: - Capture

    private static func screenshot(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard let path = args["path"], path.hasPrefix("/") else { return completion(.failure("screenshot requires an absolute --out path")) }
        automation(page, completion: completion) { automation in
            automation.screenshot(fullPage: args["full-page"] == "true") { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error.message))
                case .success(let png):
                    do {
                        let url = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try png.write(to: url)
                        let size = NSBitmapImageRep(data: png).map { " (\($0.pixelsWide)×\($0.pixelsHigh))" } ?? ""
                        completion(CLIResponse(ok: true, message: "Saved \(path)\(size).", path: path))
                    } catch {
                        completion(.failure("could not write \(path): \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    private static func startRecording(_ page: AgentPage, _ args: [String: String], completion: @escaping Completion) {
        guard page.recorder == nil else { return completion(.failure("\(page.id) is already recording")) }
        guard let directory = args["dir"], directory.hasPrefix("/") else { return completion(.failure("record start requires an absolute --out directory")) }
        let quality = min(100, max(10, args["quality"].flatMap(Int.init) ?? 90))
        let recorder: AgentRecorder
        do {
            recorder = try AgentRecorder(directory: URL(fileURLWithPath: directory))
        } catch {
            return completion(.failure("could not create \(directory): \(error.localizedDescription)"))
        }
        if args["cursor"] == "true" { page.showsCursor = true }
        automation(page, completion: completion) { automation in
            automation.startScreencast(quality: quality, onFrame: { jpeg, timestamp in
                recorder.add(jpeg, timestamp: timestamp)
            }) { result in
                if case .failure(let error) = result { return completion(.failure(error.message)) }
                page.recorder = recorder
                recorder.automation = automation
                page.controller?.agentIndicator?.isRecording = true
                completion(CLIResponse(ok: true, message: "Recording \(page.id) into \(directory).", path: directory))
            }
        }
    }

    private static func stopRecording(_ page: AgentPage, completion: @escaping Completion) {
        guard let recorder = page.recorder else { return completion(.failure("\(page.id) is not recording")) }
        page.recorder = nil
        page.controller?.agentIndicator?.isRecording = false
        recorder.automation?.stopScreencast()
        recorder.finish { result in
            switch result {
            case .failure(let error):
                completion(.failure(error.localizedDescription))
            case .success(let count):
                let directory = recorder.directory.path
                completion(CLIResponse(
                    ok: true,
                    message: """
                        Wrote \(count) frame(s) to \(directory). Make a video with:
                          ffmpeg -f concat -safe 0 -i '\(directory)/frames.ffconcat' -vf 'fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p' -c:v libx264 -crf 18 out.mp4
                        """,
                    path: directory,
                    frameCount: count))
            }
        }
    }
}

/// Writes one recording's screencast frames as numbered JPEGs, then an
/// ffconcat list that holds each frame for as long as the page showed it:
/// the engine sends a frame only when the page repaints.
final class AgentRecorder {
    let directory: URL
    weak var automation: EngineTabAutomation?
    private let queue = DispatchQueue(label: "com.browser.AgentRecorder")
    private var frames: [(name: String, timestamp: TimeInterval)] = []
    private var cancelled = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func add(_ jpeg: Data, timestamp: TimeInterval) {
        queue.async {
            guard !self.cancelled else { return }
            let name = String(format: "frame-%06d.jpg", self.frames.count + 1)
            guard (try? jpeg.write(to: self.directory.appendingPathComponent(name))) != nil else { return }
            self.frames.append((name, timestamp))
        }
    }

    func cancel() {
        automation?.stopScreencast()
        queue.async { self.cancelled = true }
    }

    /// On the main thread, with the frame count.
    func finish(completion: @escaping (Result<Int, Error>) -> Void) {
        let stoppedAt = Date().timeIntervalSince1970
        queue.async {
            self.cancelled = true
            var list = "ffconcat version 1.0\n"
            for (index, frame) in self.frames.enumerated() {
                let end = index + 1 < self.frames.count ? self.frames[index + 1].timestamp : max(stoppedAt, frame.timestamp + 0.04)
                list += "file '\(frame.name)'\nduration \(String(format: "%.4f", max(0.001, end - frame.timestamp)))\n"
            }
            // The concat demuxer ignores the last entry's duration unless
            // the file is listed once more.
            if let last = self.frames.last { list += "file '\(last.name)'\n" }
            let result = Result<Int, Error> {
                try list.write(to: self.directory.appendingPathComponent("frames.ffconcat"), atomically: true, encoding: .utf8)
                return self.frames.count
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
