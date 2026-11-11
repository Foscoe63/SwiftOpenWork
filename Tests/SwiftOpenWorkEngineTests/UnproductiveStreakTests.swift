import XCTest
@testable import SwiftOpenWorkEngine

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
