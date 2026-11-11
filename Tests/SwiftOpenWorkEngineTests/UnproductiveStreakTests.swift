import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

/// A turn that keeps trying different calls that all fail or come back empty is stopped, instead
/// of spending every remaining round re-sending the conversation.
final class UnproductiveStreakTests: XCTestCase {
    func testFailuresAndEmptySearchesAreUnproductive() {
        XCTAssertTrue(AgentTurn.isUnproductive(toolName: "terminal_command", success: false, output: "command not found: psql"))
        XCTAssertTrue(AgentTurn.isUnproductive(toolName: "glob", success: true, output: "No files match `**/.env*` under /x"))
        XCTAssertTrue(AgentTurn.isUnproductive(toolName: "grep", success: true, output: "No matches for /postgres/ in 0 files."))
    }

    func testRealResultsAreProductive() {
        XCTAssertFalse(AgentTurn.isUnproductive(toolName: "file_read", success: true, output: "/a.swift — 10 lines"))
        XCTAssertFalse(AgentTurn.isUnproductive(toolName: "glob", success: true, output: "a.swift\nb.swift"))
    }

    func testThresholds() {
        XCTAssertLessThan(AgentTurn.unproductiveNudgeAt, AgentTurn.unproductiveHaltAt)
    }
}

/// The agent's own tool list limits what the main turn is sent, not only sub-agents.
final class AgentToolAllowlistTests: XCTestCase {
    private func tool(_ name: String) -> Tool {
        Tool(id: name, name: name, displayName: name, description: "", category: .system)
    }

    func testRestrictsToTheAgentsList() {
        let all = ["file_read", "grep", "edit_file", "tool_describe"].map(tool)
        let kept = AgentTurn.restrictToAllowlist(all, allowed: ["file_read"]).map(\.name)
        XCTAssertEqual(Set(kept), ["file_read", "tool_describe"])
    }

    func testEmptyListMeansEverything() {
        let all = ["file_read", "grep"].map(tool)
        XCTAssertEqual(AgentTurn.restrictToAllowlist(all, allowed: []).count, 2)
    }
}
