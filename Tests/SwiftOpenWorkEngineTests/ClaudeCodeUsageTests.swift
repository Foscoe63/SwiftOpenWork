import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

final class ClaudeCodeUsageTests: XCTestCase {

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
