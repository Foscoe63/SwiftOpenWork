import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Sub-agents are unattended: edits inside their own worktree run, everything else that would ask
/// a person is refused.
@MainActor
final class SubAgentToolPolicyTests: XCTestCase {

    private var worktree = ""
    private var outside = ""
    private let settings = AppSettings.default

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "subagent-policy-\(UUID().uuidString)"
        worktree = base + "/sub-coder"
        outside = base + "/elsewhere"
        for dir in [worktree + "/src", worktree + "/.git", outside] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (worktree as NSString).deletingLastPathComponent)
    }

    private func reason(_ tool: String, _ args: [String: Any], worktree: String?? = .none) -> String? {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let path: String? = worktree ?? self.worktree
        return SubAgentToolPolicy.approvalReason(
            toolName: tool, argumentsJson: json, worktreePath: path, settings: settings, sessionId: "parent-chat"
        )
    }

    func testEditsInsideTheWorktreeRunUnasked() {
        XCTAssertNil(reason("file_write", ["path": "src/new.swift", "content": "x"]))
        XCTAssertNil(reason("edit_file", ["path": worktree + "/src/a.swift", "old_string": "a", "new_string": "b"]))
        XCTAssertNil(reason("multi_edit", ["path": "src/a.swift", "edits": [["old_string": "a", "new_string": "b"]]]))
        XCTAssertNil(reason("file_delete", ["path": "src/old.swift"]))
        XCTAssertNil(reason("file_move", ["source": "src/a.swift", "destination": "src/b.swift"]))
        XCTAssertNil(reason("rename_symbol", ["old_name": "a", "new_name": "b"]))
        XCTAssertNil(reason("git_commit", ["worktree_path": worktree, "message": "Work"]))
    }

    func testEditsThatLeaveTheWorktreeAreRefused() throws {
        XCTAssertNotNil(reason("file_write", ["path": outside + "/x.txt", "content": "x"]))
        XCTAssertNotNil(reason("file_write", ["path": "../elsewhere/x.txt", "content": "x"]))
        XCTAssertNotNil(reason("file_write", ["path": "~/x.txt", "content": "x"]))
        XCTAssertNotNil(reason("file_move", ["source": "src/a.swift", "destination": outside + "/a.swift"]))
        XCTAssertNotNil(reason("file_copy", ["from": outside + "/secret", "to": "src/secret"]), "copying *in* from outside reads outside too")
        XCTAssertNotNil(reason("file_delete", ["path": outside]))
        XCTAssertNotNil(reason("file_write", ["path": ".git/config", "content": "x"]), "the worktree's git metadata is not the sub-agent's")
        XCTAssertNotNil(reason("file_write", ["content": "no path"]))
        XCTAssertNotNil(reason("git_commit", ["worktree_path": outside, "message": "x"]))

        try FileManager.default.createSymbolicLink(atPath: worktree + "/link", withDestinationPath: outside)
        XCTAssertNotNil(reason("file_write", ["path": "link/new/x.txt", "content": "x"]), "a link out of the worktree is outside")
    }

    /// The dispatcher accepts `src`/`dest`/`file_path` and resolves `write`/`mv`; the policy has to
    /// judge the call as the dispatcher will run it, or an alternative spelling walks out of the
    /// worktree unasked.
    func testAlternativeSpellingsCannotEscapeTheWorktree() {
        XCTAssertNotNil(reason("file_copy", ["source": "src/a.swift", "dest": outside + "/a.swift"]))
        XCTAssertNotNil(reason("file_copy", ["source": "src/a.swift", "destination_path": outside + "/a.swift"]))
        XCTAssertNotNil(reason("file_move", ["src": outside + "/secret", "destination": "src/secret"]))
        XCTAssertNotNil(reason("mv", ["from": "src/a.swift", "dst": outside + "/a.swift"]))
        XCTAssertNotNil(reason("write", ["file_path": outside + "/x.txt", "content": "x"]))
        XCTAssertNotNil(reason("edit", ["file_path": "../elsewhere/x.txt", "old_string": "a", "new_string": "b"]))
        XCTAssertNotNil(reason("delete", ["file_path": outside]))
        // One key inside and another outside: the outside one counts.
        XCTAssertNotNil(reason("edit_file", ["path": "src/a.swift", "file_path": outside + "/x", "old_string": "a", "new_string": "b"]))
    }

    func testAliasedEditsInsideTheWorktreeStillRun() {
        XCTAssertNil(reason("write", ["file_path": "src/new.swift", "content": "x"]))
        XCTAssertNil(reason("edit", ["file_path": worktree + "/src/a.swift", "old_string": "a", "new_string": "b"]))
        XCTAssertNil(reason("mv", ["src": "src/a.swift", "dst": "src/b.swift"]))
    }

    func testWithoutAWorktreeEveryEditIsRefused() {
        XCTAssertNotNil(reason("file_write", ["path": "src/new.swift", "content": "x"], worktree: .some(nil)))
        XCTAssertNotNil(reason("file_delete", ["path": "src/old.swift"], worktree: .some(nil)))
    }

    func testEverythingElseThatAsksIsRefused() {
        XCTAssertNotNil(reason("run_app", ["path": "App.app"]))
        XCTAssertNotNil(reason("worktree_remove", ["name": "x"]))
        XCTAssertNotNil(reason("revert_changes", [:]), "a sub-agent must not undo the parent's turn")
        XCTAssertNotNil(reason("preview_start", ["command": "npm run dev"]))
        XCTAssertNotNil(reason("fetch_url", ["url": "https://never-approved.example/"]))
    }

    func testReadsAndSearchesNeverAsk() {
        XCTAssertNil(reason("file_read", ["path": outside + "/notes.txt"]))
        XCTAssertNil(reason("grep", ["pattern": "TODO"]))
        XCTAssertNil(reason("build_project", [:]))
    }

    func testAlwaysAskShellIsRefusedAndSafeShellIsNot() {
        var strict = settings
        strict.terminalSafetyLevel = .alwaysAsk
        let json = #"{"command":"ls"}"#
        XCTAssertNotNil(SubAgentToolPolicy.approvalReason(toolName: "terminal_command", argumentsJson: json, worktreePath: worktree, settings: strict, sessionId: "s"))
        XCTAssertNil(SubAgentToolPolicy.approvalReason(toolName: "terminal_command", argumentsJson: json, worktreePath: worktree, settings: settings, sessionId: "s"))
    }
}
