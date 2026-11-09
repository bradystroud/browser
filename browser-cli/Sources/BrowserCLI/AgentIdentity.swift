import Foundation

/// Which coding agent is running this `browser page` command, so the agent
/// window's strip can name it: the tool (Claude Code, Codex), the session's
/// own name in that tool, and the model.
///
/// Everything comes from what the tool leaves for its child processes and
/// on disk -- nothing is sent by the agent itself unless it passes `--agent`
/// or `--model` (or sets `BROWSER_AGENT_NAME`/`BROWSER_AGENT_MODEL`), which
/// always win. Any field that cannot be found is left out, never guessed.
///
/// It runs on every page command, not only `open`, because both tools rename
/// a session as it goes and `/model` switches the model mid-session.
struct AgentIdentity: Equatable {
    var tool: String?
    var name: String?
    var model: String?

    /// The keys the app reads (`AgentPages.applyIdentity`).
    var requestArgs: [String: String] {
        var args: [String: String] = [:]
        if let tool { args["agent-tool"] = tool }
        if let name { args["agent-name"] = name }
        if let model { args["agent-model"] = model }
        return args
    }

    static func detect(
        flags: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentIdentity {
        var identity: AgentIdentity
        if environment["CLAUDECODE"] == "1" || environment["CLAUDE_CODE_SESSION_ID"] != nil {
            identity = claudeCode(environment: environment, home: home)
        } else if let threadId = nonEmpty(environment["CODEX_THREAD_ID"]) {
            identity = codex(threadId: threadId, home: home)
        } else if let agent = nonEmpty(environment["AI_AGENT"]) {
            identity = AgentIdentity(tool: displayName(forAIAgent: agent))
        } else {
            identity = AgentIdentity()
        }
        if let name = nonEmpty(flags["agent"]) ?? nonEmpty(environment["BROWSER_AGENT_NAME"]) {
            identity.name = name
        }
        if let model = nonEmpty(flags["model"]) ?? nonEmpty(environment["BROWSER_AGENT_MODEL"]) {
            identity.model = model
        }
        return identity
    }

    // MARK: - Claude Code

    /// Claude Code's transcript is `~/.claude/projects/<project>/<session>.jsonl`.
    /// Its session name is the newest `agent-name` (set with /rename), else
    /// `custom-title`, else the generated `ai-title`; its model is the newest
    /// assistant message's `model`.
    private static func claudeCode(environment: [String: String], home: URL) -> AgentIdentity {
        var identity = AgentIdentity(tool: "Claude Code")
        let configDir = nonEmpty(environment["CLAUDE_CONFIG_DIR"]).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        guard let sessionId = nonEmpty(environment["CLAUDE_CODE_SESSION_ID"]),
              let transcript = findFile(named: "\(sessionId).jsonl", in: configDir.appendingPathComponent("projects")),
              let text = readTail(of: transcript)
        else { return identity }
        let parsed = parseClaudeTranscript(text)
        identity.name = parsed.name
        identity.model = parsed.model
        return identity
    }

    static func parseClaudeTranscript(_ text: String) -> (name: String?, model: String?) {
        var agentName: String?, customTitle: String?, aiTitle: String?, model: String?
        for line in text.split(separator: "\n").reversed() {
            if agentName == nil, line.contains("\"agent-name\""), let value = jsonString("agentName", in: line) { agentName = value }
            if customTitle == nil, line.contains("\"custom-title\""), let value = jsonString("customTitle", in: line) { customTitle = value }
            if aiTitle == nil, line.contains("\"ai-title\""), let value = jsonString("aiTitle", in: line) { aiTitle = value }
            if model == nil, line.contains("\"type\":\"assistant\""), let value = jsonString("model", in: line),
               !value.hasPrefix("<") {
                model = value
            }
            if agentName != nil, model != nil { break }
        }
        return (agentName ?? customTitle ?? aiTitle, model)
    }

    // MARK: - Codex

    /// Codex names threads in `~/.codex/session_index.jsonl` (newest entry
    /// last) and records each turn's model in the thread's rollout file,
    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread>.jsonl`.
    private static func codex(threadId: String, home: URL) -> AgentIdentity {
        var identity = AgentIdentity(tool: "Codex")
        let codexDir = home.appendingPathComponent(".codex")
        if let index = readTail(of: codexDir.appendingPathComponent("session_index.jsonl")) {
            identity.name = parseCodexThreadName(index, threadId: threadId)
        }
        if let rollout = findFile(suffix: "-\(threadId).jsonl", in: codexDir.appendingPathComponent("sessions")),
           let text = readTail(of: rollout) {
            identity.model = lastJSONString("model", in: text)
        }
        if identity.model == nil, let config = try? String(contentsOf: codexDir.appendingPathComponent("config.toml"), encoding: .utf8) {
            identity.model = parseCodexConfigModel(config)
        }
        return identity
    }

    static func parseCodexThreadName(_ index: String, threadId: String) -> String? {
        for line in index.split(separator: "\n").reversed() where line.contains(threadId) {
            if jsonString("id", in: line) == threadId, let name = jsonString("thread_name", in: line) { return name }
        }
        return nil
    }

    /// The top-level `model = "..."`, before any `[table]`.
    static func parseCodexConfigModel(_ config: String) -> String? {
        for rawLine in config.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("model"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") else { return nil }
            return nonEmpty(String(value[value.index(after: value.startIndex)..<close]))
        }
        return nil
    }

    // MARK: - Helpers

    /// `AI_AGENT` is `<tool>_<version>_<kind>`, e.g. `claude-code_2-1-317_agent`.
    static func displayName(forAIAgent value: String) -> String {
        let tool = value.split(separator: "_").first.map(String.init) ?? value
        switch tool {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return tool
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The value of `"key":"..."` in one JSON line, decoded properly so
    /// escapes and non-ASCII names come out right.
    private static func jsonString(_ key: String, in line: Substring) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let value = object[key] as? String { return nonEmpty(value) }
        // Claude Code nests the model inside the assistant message.
        if let message = object["message"] as? [String: Any], let value = message[key] as? String { return nonEmpty(value) }
        return nil
    }

    private static func lastJSONString(_ key: String, in text: String) -> String? {
        let pattern = "\"\(key)\":\"([^\"\\\\]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    /// The last `limit` bytes, from the first whole line in them: transcripts
    /// grow to many megabytes and only their newest entries matter here.
    private static func readTail(of url: URL, limit: Int = 4 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    private static func findFile(named name: String, in directory: URL) -> URL? {
        guard let projects = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for project in projects {
            let candidate = project.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The newest match: rollout paths sort by date.
    private static func findFile(suffix: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        var newest: URL?
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            if newest == nil || url.path > newest!.path { newest = url }
        }
        return newest
    }
}
