import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Which calls may run side by side. Being wrong in the permissive direction would reorder an
/// edit against a read, or run a shell command the model meant to run last.
final class ParallelToolCallTests: XCTestCase {
    func testReadOnlyToolsAndTheirAliasesAreParallelSafe() {
        for name in ["file_read", "read_file", "cat", "grep", "rg", "glob", "file_list", "git_diff"] {
            XCTAssertTrue(AgentRunner.isParallelSafe(name), name)
        }
    }

    func testAnythingThatChangesStateOrIsUnknownIsNot() {
        for name in ["file_write", "edit_file", "multi_edit", "file_delete", "terminal_command", "bash",
                     "git_commit", "agent_spawn", "ask_user", "mcp__Server__Tool", "totally_unknown"] {
            XCTAssertFalse(AgentRunner.isParallelSafe(name), name)
        }
    }

    func testNothingParallelSafeChangesFiles() {
        for name in ToolCallRepair.builtInNames where AgentRunner.isParallelSafe(name) {
            XCTAssertFalse(AgentRunner.changesFiles(name), name)
        }
    }

    /// Several delegations in one step start together, except on the local engine, which runs one
    /// generation at a time anyway.
    func testSpawnsRunTogetherOnlyWhenThereAreSeveralAndTheModelIsNotLocal() {
        let cloud = ModelProvider(id: "c", name: "Cloud", type: .cloud, kind: .openai, isEnabled: true)
        let local = ModelProvider(id: "l", name: "Local", type: .local, kind: .omlx, isEnabled: true)
        XCTAssertTrue(AgentRunner.spawnsRunTogether(["agent_spawn", "file_read", "agent_spawn"], provider: cloud))
        XCTAssertFalse(AgentRunner.spawnsRunTogether(["agent_spawn", "file_read"], provider: cloud), "one spawn has nothing to overlap with")
        XCTAssertFalse(AgentRunner.spawnsRunTogether(["agent_spawn", "agent_spawn"], provider: local))
        XCTAssertFalse(AgentRunner.isParallelSafe("agent_spawn"), "a spawn is not a read: it only joins a step that delegates more than once")
    }
}
