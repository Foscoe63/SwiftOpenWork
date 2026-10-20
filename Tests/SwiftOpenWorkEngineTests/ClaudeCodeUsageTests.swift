import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

final class ClaudeCodeUsageTests: XCTestCase {

    func testTurnSumsEveryCallSinceTheTurnStartedIncludingCacheReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-turn-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let start = Date()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ id: String, at: Date, input: Int, read: Int, output: Int) -> String {
            """
            {"type":"assistant","sessionId":"s1","requestId":"r-\(id)","timestamp":"\(stamp.string(from: at))","message":{"id":"m-\(id)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":\(read)}}}
            """
        }
        let lines = [
            line("old", at: start.addingTimeInterval(-600), input: 1, read: 9_000, output: 9),   // an earlier turn
            line("a", at: start.addingTimeInterval(1), input: 3, read: 20_000, output: 40),
            line("b", at: start.addingTimeInterval(2), input: 4, read: 30_000, output: 60),
            line("b", at: start.addingTimeInterval(2), input: 4, read: 30_000, output: 60),      // second content block
        ]
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let turn = try XCTUnwrap(ClaudeCodeUsage.turn(configDir: dir.path, sessionId: "s1", since: start))
        XCTAssertEqual(turn.calls, 2)
        XCTAssertEqual(turn.rawSent, 20_003 + 30_004)
        XCTAssertEqual(turn.sent, 3 + 2_000 + 4 + 3_000)   // cache reads count a tenth
        XCTAssertEqual(turn.received, 100)
        XCTAssertEqual(turn.lastPrompt, 30_004)
        XCTAssertNil(ClaudeCodeUsage.turn(configDir: dir.path, sessionId: "missing", since: start))
    }

    func testScanCountsEachReplyOnceAndSplitsBySession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-usage-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ id: String, session: String, at: Date, output: Int) -> String {
            """
            {"type":"assistant","sessionId":"\(session)","requestId":"r-\(id)","timestamp":"\(stamp.string(from: at))","message":{"id":"m-\(id)","model":"claude-sonnet-5-5","usage":{"input_tokens":10,"output_tokens":\(output),"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}
            """
        }
        let lines = [
            line("1", session: "s1", at: now.addingTimeInterval(-60), output: 5),
            line("1", session: "s1", at: now.addingTimeInterval(-60), output: 5),   // same reply, second content block
            line("2", session: "s2", at: now.addingTimeInterval(-86_400 * 3), output: 7),
            line("3", session: "s2", at: now.addingTimeInterval(-86_400 * 30), output: 9), // too old
        ]
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let usage = ClaudeCodeUsage.scan(configDir: dir.path, now: now)
        XCTAssertEqual(usage.last5Hours.messages, 1)
        XCTAssertEqual(usage.last5Hours.output, 5)
        XCTAssertEqual(usage.last7Days.messages, 2)
        XCTAssertEqual(usage.bySession["s1"]?.total, 10 + 5 + 100 + 1000)
        XCTAssertEqual(usage.byModel.first?.model, "claude-sonnet-5-5")
    }

    func testConfigDirFollowsTheAgentsEnvironment() {
        let second = ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/claude-code-acp"], env: ["CLAUDE_CONFIG_DIR": "/tmp/x"])
        XCTAssertEqual(ClaudeCodeUsage.configDir(for: second), "/tmp/x")
        let first = ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/claude-code-acp"])
        XCTAssertEqual(ClaudeCodeUsage.configDir(for: first), ClaudeCodeUsage.defaultConfigDir)
        XCTAssertNil(ClaudeCodeUsage.configDir(for: ExternalAgentConfig(command: "opencode", args: ["acp"])))
    }
}

final class ExternalAgentModelTests: XCTestCase {
    private let claude = ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/claude-code-acp"])

    func testClaudeCodeDefaultsToSonnetAndLean() {
        XCTAssertEqual(claude.effectiveModel, "sonnet")
        XCTAssertTrue(claude.effectiveLeanContext)
        XCTAssertNotNil(ACPAgentRunner.sessionMeta(for: claude))
    }

    func testExplicitModelAndDefaultAreHonoured() {
        var config = claude
        config.model = "Opus"
        XCTAssertEqual(config.effectiveModel, "opus")
        config.model = "default"
        XCTAssertNil(config.effectiveModel)
    }

    func testOtherAgentsAreLeftAlone() {
        let codex = ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/codex-acp"])
        XCTAssertNil(codex.effectiveModel)
        XCTAssertNil(ACPAgentRunner.sessionMeta(for: codex))
    }
}
