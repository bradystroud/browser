import XCTest
@testable import BrowserCLI

final class AgentIdentityTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testClaudeCodeUsesNewestRenameOverGeneratedTitle() throws {
        try write("""
            {"type":"ai-title","aiTitle":"Old title","sessionId":"s1"}
            {"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}
            {"type":"agent-name","agentName":"refactor","sessionId":"s1"}
            {"type":"ai-title","aiTitle":"Newer title","sessionId":"s1"}
            {"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}
            {"type":"assistant","message":{"model":"<synthetic>","content":[]}}
            """, to: ".claude/projects/-Users-me-repo/s1.jsonl")
        let identity = AgentIdentity.detect(flags: [:], environment: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s1"], home: home)
        XCTAssertEqual(identity, AgentIdentity(tool: "Claude Code", name: "refactor", model: "claude-opus-5-5"))
    }

    func testClaudeCodeFallsBackToGeneratedTitle() {
        let parsed = AgentIdentity.parseClaudeTranscript("""
            {"type":"ai-title","aiTitle":"First"}
            {"type":"ai-title","aiTitle":"Agent “banner” work"}
            """)
        XCTAssertEqual(parsed.name, "Agent “banner” work")
        XCTAssertNil(parsed.model)
    }

    func testClaudeCodeWithNoTranscriptStillNamesTheTool() {
        let identity = AgentIdentity.detect(flags: [:], environment: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "missing"], home: home)
        XCTAssertEqual(identity, AgentIdentity(tool: "Claude Code"))
    }

    func testCodexReadsThreadNameAndRolloutModel() throws {
        try write("""
            {"id":"t1","thread_name":"First name","updated_at":"2026-11-01T00:00:00Z"}
            {"id":"t2","thread_name":"Other","updated_at":"2026-11-01T00:00:00Z"}
            {"id":"t1","thread_name":"Renamed","updated_at":"2026-11-02T00:00:00Z"}
            """, to: ".codex/session_index.jsonl")
        try write("""
            {"type":"turn_context","payload":{"model":"gpt-6"}}
            {"type":"turn_context","payload":{"model":"gpt-6-astra"}}
            """, to: ".codex/sessions/2026/11/09/rollout-2026-11-09T10-00-00-t1.jsonl")
        try write("model = \"ignored\"\n", to: ".codex/config.toml")
        let identity = AgentIdentity.detect(flags: [:], environment: ["CODEX_THREAD_ID": "t1"], home: home)
        XCTAssertEqual(identity, AgentIdentity(tool: "Codex", name: "Renamed", model: "gpt-6-astra"))
    }

    func testCodexConfigModelIsTopLevelOnly() {
        XCTAssertEqual(AgentIdentity.parseCodexConfigModel("model_reasoning_effort = \"low\"\nmodel = \"gpt-6\"\n"), "gpt-6")
        XCTAssertNil(AgentIdentity.parseCodexConfigModel("[profiles.fast]\nmodel = \"gpt-6-mini\"\n"))
    }

    func testFlagsAndEnvironmentOverrideDetection() {
        let identity = AgentIdentity.detect(
            flags: ["agent": "reviewer"],
            environment: ["AI_AGENT": "claude-code_2-1-317_agent", "BROWSER_AGENT_MODEL": "claude-haiku-5-5"],
            home: home)
        XCTAssertEqual(identity, AgentIdentity(tool: "Claude Code", name: "reviewer", model: "claude-haiku-5-5"))
    }

    func testNoAgentSendsNothing() {
        XCTAssertTrue(AgentIdentity.detect(flags: [:], environment: [:], home: home).requestArgs.isEmpty)
    }
}
