import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Git status and history, worktrees, commits and pull requests.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let gitToolHandlers: [ToolRegistration] = [
        ToolRegistration(["git_status"]) { await $0.gitStatusTool($1) },
        ToolRegistration(["git_diff"]) { await $0.gitDiffTool($1) },
        ToolRegistration(["git_log"]) { await $0.gitLogTool($1) },
        ToolRegistration(["changed_files"]) { await $0.changedFilesTool($1) },
        ToolRegistration(["revert_changes"]) { await $0.revertChangesTool($1) },
        ToolRegistration(["worktree_create"]) { await $0.worktreeCreateTool($1) },
        ToolRegistration(["worktree_list"]) { await $0.worktreeListTool($1) },
        ToolRegistration(["worktree_remove"]) { await $0.worktreeRemoveTool($1) },
        ToolRegistration(["worktree_merge"]) { await $0.worktreeMergeTool($1) },
        ToolRegistration(["pr_status"]) { await $0.prStatusTool($1) },
        ToolRegistration(["pr_create"]) { await $0.prCreateTool($1) },
        ToolRegistration(["git_commit"]) { await $0.gitCommitTool($1) },
    ]

    func gitStatusTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let workspace = call.workspace
        let startTime = call.startTime
        let out = GitTools.status(in: workspace.folderPath)
        return ToolExecutionResult(
            success: out.isRepository, output: out.text,
            error: out.isRepository ? nil : out.text,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func gitDiffTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let target = (dict["path"] as? String) ?? (dict["file"] as? String)
        let staged = (dict["staged"] as? Bool) ?? false
        let out = GitTools.diff(in: workspace.folderPath, path: target, staged: staged)
        return ToolExecutionResult(
            success: out.isRepository, output: out.text,
            error: out.isRepository ? nil : out.text,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func gitLogTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let count = Self.intArgument(dict["count"]) ?? Self.intArgument(dict["limit"]) ?? 10
        let out = GitTools.log(in: workspace.folderPath, count: count)
        return ToolExecutionResult(
            success: out.isRepository, output: out.text,
            error: out.isRepository ? nil : out.text,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func changedFilesTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let workspace = call.workspace
        let startTime = call.startTime
        let summary = await FileCheckpointStore.shared.summary()
        return ToolExecutionResult(
            success: true,
            output: FileCheckpointStore.describe(summary, root: workspace.folderPath),
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func revertChangesTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let workspace = call.workspace
        let startTime = call.startTime
        let summary = await FileCheckpointStore.shared.summary()
        guard !summary.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "Nothing to revert — this turn has not changed any files.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let outcome = await FileCheckpointStore.shared.revertTurn()
        return ToolExecutionResult(
            success: outcome.failed.isEmpty,
            output: FileCheckpointStore.describe(outcome, root: workspace.folderPath),
            error: outcome.failed.isEmpty ? nil : "Some files could not be reverted.",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func worktreeCreateTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let name = (dict["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return Self.failure("worktree_create needs a 'name' for the task being isolated.", startTime)
        }
        do {
            let info = try await AgentWorktree.create(workspacePath: workspace.folderPath, name: name)
            return ToolExecutionResult(
                success: true,
                output: """
                Worktree ready at \(info.path)
                Branch: \(info.branch) (from \(info.head))

                Work in that directory by absolute path. Changes there do not touch the main                     checkout, and git_commit can checkpoint them.
                """,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
    }

    func worktreeListTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let workspace = call.workspace
        let startTime = call.startTime
        do {
            let trees = try await AgentWorktree.list(workspacePath: workspace.folderPath)
            guard !trees.isEmpty else {
                return ToolExecutionResult(success: true, output: "No agent worktrees.", durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            }
            let body = trees.map { "- \($0.branch) @ \($0.head)\n  \($0.path)" }.joined(separator: "\n")
            return ToolExecutionResult(success: true, output: body, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
    }

    func worktreeRemoveTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let name = (dict["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let force = dict["force"] as? Bool ?? false
        guard !name.isEmpty else {
            return Self.failure("worktree_remove needs a 'name'.", startTime)
        }
        do {
            let message = try await AgentWorktree.remove(workspacePath: workspace.folderPath, name: name, force: force)
            return ToolExecutionResult(success: true, output: message, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
    }

    func worktreeMergeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let name = (dict["name"] as? String ?? dict["branch"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return Self.failure("worktree_merge needs a 'name': the worktree or branch a sub-agent reported.", startTime)
        }
        let rawStrategy = (dict["strategy"] as? String ?? "apply").trimmingCharacters(in: .whitespaces).lowercased()
        guard let strategy = AgentWorktree.MergeStrategy(rawValue: rawStrategy) else {
            return Self.failure("worktree_merge strategy must be 'apply' or 'merge'.", startTime)
        }
        do {
            let plan = try await AgentWorktree.planMerge(workspacePath: workspace.folderPath, name: name)
            // Applied edits join this turn's undo window, as any other edit does.
            if strategy == .apply {
                for file in plan.files {
                    await FileCheckpointStore.shared.record(path: plan.repoRoot.appendingPathComponent(file).path)
                }
            }
            let message = try await AgentWorktree.merge(plan, strategy: strategy)
            return ToolExecutionResult(success: true, output: message, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
    }

    func prStatusTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let wantsLogs = Self.boolArgument(dict["include_failed_logs"]) == true
        let lookup = await PullRequestTools.lookup(in: workspace.folderPath)
        var logs: String?
        if wantsLogs, case let .status(status) = lookup, !status.failing.isEmpty {
            logs = await PullRequestTools.failedLogs(in: workspace.folderPath)
        }
        let described = PullRequestTools.describe(lookup, failedLogs: logs)
        return ToolExecutionResult(
            success: described.success, output: described.success ? described.text : "",
            error: described.success ? nil : described.text,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func prCreateTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return Self.failure("pr_create needs a title.", startTime) }
        let created = await PullRequestTools.create(
            in: workspace.folderPath, title: title, body: dict["body"] as? String ?? "",
            base: (dict["base"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            draft: Self.boolArgument(dict["draft"]) == true
        )
        return ToolExecutionResult(
            success: created.success, output: created.success ? created.text : "",
            error: created.success ? nil : created.text,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func gitCommitTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let rawPath = (dict["worktree_path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let message = dict["message"] as? String ?? ""
        let target = rawPath.isEmpty ? workspace.folderPath : rawPath
        do {
            let result = try await AgentWorktree.commit(worktreePath: target, message: message)
            return ToolExecutionResult(success: true, output: result, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
    }
}
