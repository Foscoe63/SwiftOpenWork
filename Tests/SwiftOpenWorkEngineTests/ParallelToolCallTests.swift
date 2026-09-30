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
}
