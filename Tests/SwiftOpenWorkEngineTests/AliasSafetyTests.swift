import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Loose aliases must not be a way around a safety check.
@MainActor
final class AliasesDoNotBypassSafetyTests: XCTestCase {
    private var settings: AppSettings { AppSettings.default }

    func testAliasedDeleteStillAsksForApproval() {
        for name in ["delete", "remove", "unlink", "rm", "delete_file", "file_delete"] {
            XCTAssertNotNil(
                AgentRunner.approvalReason(toolName: name, argumentsJson: #"{"path":"a.txt"}"#, settings: settings),
                "\(name) deletes a file and must ask"
            )
        }
    }

    func testAliasedWritesStillAsk() {
        for name in ["write", "edit", "str_replace", "create", "multiedit", "mv", "cp"] {
            XCTAssertNotNil(AgentRunner.approvalReason(toolName: name, argumentsJson: "{}", settings: settings), name)
        }
    }

    func testAlternativeArgumentKeysAreStillCheckedForSensitivePaths() {
        let plain = AgentRunner.approvalReason(toolName: "file_read", argumentsJson: #"{"path":"~/.ssh/id_rsa"}"#, settings: settings)
        let aliased = AgentRunner.approvalReason(toolName: "read", argumentsJson: #"{"file_path":"~/.ssh/id_rsa"}"#, settings: settings)
        XCTAssertEqual(plain, aliased, "spelling the tool or its key differently must not change the decision")
    }

    func testPlanModeBlocksAliasesOfMutatingTools() {
        for name in ["bash", "shell", "run", "write", "edit", "delete", "mv", "file_write", "terminal_command", "revert_changes"] {
            XCTAssertTrue(ToolCallRepair.isBlockedInPlanMode(name), name)
        }
        for name in ["read", "grep", "glob", "file_list", "git_status", "mcp__srv__thing"] {
            XCTAssertFalse(ToolCallRepair.isBlockedInPlanMode(name), name)
        }
    }

    func testBuiltInCanonicalIgnoresNonBuiltIns() {
        XCTAssertNil(ToolCallRepair.builtInCanonical("mcp__Server__Tool"))
        XCTAssertNil(ToolCallRepair.builtInCanonical("totally_unknown"))
        XCTAssertEqual(ToolCallRepair.builtInCanonical("Bash"), "terminal_command")
    }
}
