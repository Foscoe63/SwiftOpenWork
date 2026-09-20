import Foundation
import SwiftOpenWorkCore

/// Which of a sub-agent's tool calls need a person, and so are refused: a sub-agent runs
/// unattended, and nobody is there to ask.
///
/// Sub-agents used to run every tool straight through `ToolExecutionEngine`, skipping approval
/// entirely — `file_delete`, `run_app`, `git_commit` and shell commands under "Always Ask" ran
/// without asking, while the prompt promised they would be refused. Enforcing `approvalReason` as
/// it stands would refuse file edits too, which is the work sub-agents exist for. The line that
/// keeps both: **edits inside the sub-agent's own worktree are its own business**, since nothing
/// there reaches the user's checkout until they merge it; everything else that would ask a person
/// is refused and reported. With no worktree — the workspace is not a git repository — an edit
/// would land in the user's files, so it asks, and is refused.
public enum SubAgentToolPolicy {

    /// Tools that only change files at the paths their arguments name.
    public static let fileEditTools: Set<String> = [
        "file_write", "write_file", "create_file", "save_file",
        "edit_file", "file_edit", "multi_edit", "edit_file_multi",
        "file_move", "move_file", "mv",
        "file_copy", "copy_file", "cp",
        "file_delete", "delete_file", "rm",
        "rename_symbol",
    ]

    /// Why this call would need a person, or nil when a sub-agent may run it.
    @MainActor
    public static func approvalReason(
        toolName: String,
        argumentsJson: String,
        worktreePath: String?,
        settings: AppSettings,
        sessionId: String,
        workspaceRoot: String? = nil
    ) -> String? {
        guard let reason = AgentRunner.approvalReason(
            toolName: toolName, argumentsJson: argumentsJson, settings: settings, sessionId: sessionId,
            workspaceRoot: workspaceRoot ?? worktreePath ?? ""
        ) else { return nil }
        guard let worktreePath else { return reason }

        let args = arguments(argumentsJson)
        if fileEditTools.contains(toolName) {
            let paths = targetPaths(toolName: toolName, arguments: args)
            // `rename_symbol` may name no file: it then works across the workspace root, which
            // for a sub-agent is the worktree.
            if paths.isEmpty && toolName != "rename_symbol" { return reason }
            return paths.allSatisfy { isInside($0, worktree: worktreePath) } ? nil : reason
        }
        if toolName == "git_commit" {
            let target = (args["worktree_path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return sameFolder(target, worktreePath) ? nil : reason
        }
        return reason
    }

    /// Every path a file tool's arguments name, under any of the keys the engine accepts.
    static func targetPaths(toolName: String, arguments: [String: Any]) -> [String] {
        let keys: [String]
        switch toolName {
        case "file_move", "move_file", "mv", "file_copy", "copy_file", "cp":
            keys = ["source", "from", "path", "destination", "to", "target"]
        case "rename_symbol":
            keys = ["path", "file"]
        default:
            keys = ["path", "filename", "filepath", "file", "title"]
        }
        var paths = keys.compactMap { arguments[$0] as? String }.map { $0.trimmingCharacters(in: .whitespaces) }
        // multi_edit may carry per-edit paths.
        if let edits = arguments["edits"] as? [[String: Any]] {
            paths += edits.compactMap { ($0["path"] as? String) ?? ($0["file"] as? String) }
        }
        return paths.filter { !$0.isEmpty }
    }

    /// Relative paths resolve against the worktree, as the engine resolves them against the
    /// sub-agent's workspace. `.git` inside it is not the sub-agent's to write.
    static func isInside(_ path: String, worktree: String) -> Bool {
        let root = ToolExecutionEngine.canonicalPath(worktree)
        let absolute = path.hasPrefix("/") || path.hasPrefix("~") ? path : (worktree as NSString).appendingPathComponent(path)
        let resolved = ToolExecutionEngine.canonicalPath(absolute)
        guard resolved.hasPrefix(root + "/") else { return false }
        let inner = resolved.dropFirst(root.count + 1).split(separator: "/")
        return !inner.contains(".git")
    }

    static func sameFolder(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && ToolExecutionEngine.canonicalPath(a) == ToolExecutionEngine.canonicalPath(b)
    }

    private static func arguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }
}
