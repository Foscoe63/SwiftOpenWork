import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Regressions from an audit of tool calling, MCP and the agent loop. Each test names the failure
/// it stops from coming back.
@MainActor
final class ToolAndMCPAuditTests: XCTestCase {

    // MARK: - Names a provider will accept

    func testShortNamesAreLeftAlone() {
        XCTAssertEqual(MCPNamespacedTool.name(serverId: "srv-1", toolName: "read_file"), "mcp__srv-1__read_file")
    }

    // MARK: - Effect classification

    func testNounLikeVerbsAfterAReadWordAreReads() {
        for name in ["get_commit", "get_workflow_run", "get_merge_request", "get_post", "list_starred_repositories"] {
            XCTAssertFalse(MCPEffectCatalog.nameSuggestsWrite(name), name)
        }
    }

    func testNewlyRecognisedWriteVerbsAndJoinedActions() {
        for name in ["add_sub_issue", "save_note", "star_repository", "deploy_service", "get_or_create_repository", "list_and_archive"] {
            XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite(name), name)
        }
    }

    func testACommonWordInAServerNameDoesNotPickTheFilesystemTable() {
        XCTAssertNil(MCPEffectCatalog.entry(for: MCPServerConfig(id: "a", name: "Profiles", command: "./x")))
        XCTAssertEqual(MCPEffectCatalog.entry(for: MCPServerConfig(id: "b", name: "Local Files", command: "./x"))?.key, "filesystem")
    }

    /// `retain` writes a memory but shares no token with the mutating-verb list, and a server
    /// named "Hindsight Memory" word-matches the generic `memory` table (built for the reference
    /// `server-memory` package) whose write list doesn't know Hindsight's tool names. Both checks
    /// used to fall through to "read", which let plan mode call it despite being read-only.
    func testRetainIsRecognisedAsAWriteEvenOnAServerNamedMemory() {
        XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite("retain"))
        let hindsight = MCPServerConfig(id: "mcp-hindsight", name: "Hindsight Memory", command: "", url: "http://127.0.0.1:8888/mcp/swiftopenwork")
        XCTAssertEqual(MCPEffectCatalog.classify(server: hindsight, toolName: "retain", advertised: true), .write)
        XCTAssertEqual(MCPEffectCatalog.classify(server: hindsight, toolName: "recall", advertised: true), .read)
        XCTAssertEqual(MCPEffectCatalog.classify(server: hindsight, toolName: "reflect", advertised: true), .read)
    }

    // MARK: - Processes

    /// A check command whose child outlives it must not stall the loop.
    func testALoopCheckThatTimesOutWithAStrayChildStillReturns() {
        let started = Date()
        let result = LoopCheckCommand.runBlocking("sleep 30 & echo hi; sleep 30", in: NSTemporaryDirectory(), timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 12)
    }

    func testALoopCheckWhoseBackgroundChildKeepsThePipeOpenStillReturns() {
        let started = Date()
        let result = LoopCheckCommand.runBlocking("(sleep 20 &) ; echo done; exit 3", in: NSTemporaryDirectory(), timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(result.output.contains("done"))
    }
}
