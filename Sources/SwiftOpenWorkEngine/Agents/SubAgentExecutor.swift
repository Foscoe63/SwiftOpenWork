import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// A sub-agent that actually does the work.
///
/// Sub-agents used to be theatre. `agent_spawn` built a `SubAgentTask` record, returned
/// "Spawned sub-agent […] to execute task", and ran nothing at all; the auto-delegation path
/// made one LLM call with `tools: []` and a 512-token ceiling and pasted the paragraph back. The
/// inspector drew a "Sub-Agent Tree" with a Software Engineer, a Deep Research Agent and a Code
/// Review critic above a system that could not open a file.
///
/// A real sub-agent needs four things, and the fourth is the one that makes the other three safe:
///
/// 1. **Tools** — its own ReAct loop, not a single completion.
/// 2. **A budget** — iterations and wall-clock, because nobody is watching it.
/// 3. **Unattended approvals** — it must refuse what needs a person and *say it refused*, rather
///    than blocking forever on a dialog nobody will see.
/// 4. **Isolation** — its own git worktree. Without this, concurrent sub-agents write over each
///    other and over you: `FileCheckpointStore` is turn-scoped, so a sub-agent editing the
///    parent's tree corrupts the parent's undo window as a side effect.
public enum SubAgentExecutor {

    public struct Outcome: Sendable {
        public var succeeded: Bool
        public var summary: String
        public var toolCallsMade: [String]
        public var filesChanged: [String]
        public var refusedActions: [String]
        public var worktreePath: String?
        public var branch: String?
        public var iterations: Int
        public var stoppedBecause: String
        public var durationMs: Double

        /// What the parent agent is told. A sub-agent that edited files and says only "done" is
        /// worse than useless — the parent cannot review what it cannot see.
        public var report: String {
            var lines: [String] = []
            lines.append(succeeded ? "Sub-agent completed." : "Sub-agent did not complete: \(stoppedBecause)")
            if let branch, let worktreePath {
                lines.append("Worked in an isolated worktree on `\(branch)`:\n  \(worktreePath)")
            }
            if !filesChanged.isEmpty {
                lines.append("Files changed (\(filesChanged.count)):\n" + filesChanged.map { "  \($0)" }.joined(separator: "\n"))
            } else {
                lines.append("No files were changed.")
            }
            if !toolCallsMade.isEmpty {
                lines.append("Tools used: \(toolCallsMade.joined(separator: ", "))")
            }
            if !refusedActions.isEmpty {
                lines.append("Refused (needs a person to approve):\n" + refusedActions.map { "  \($0)" }.joined(separator: "\n"))
            }
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append("\nIts report:\n\(trimmed)") }
            return lines.joined(separator: "\n")
        }
    }

    /// Tools a sub-agent may never have, whatever its configuration says.
    ///
    /// `ask_user` would block forever — there is nobody watching a sub-agent. `exit_plan_mode`
    /// belongs to the turn the user is in. `agent_spawn` is gated separately, by depth.
    public static let neverAvailable: Set<String> = ["ask_user", "exit_plan_mode"]

    @MainActor
    public static func toolSet(
        for subAgent: Agent,
        depth: Int,
        settings: AppSettings,
        all: [Tool]
    ) -> [Tool] {
        let canRecurse = AgentRunner.subAgentSpawningAllowed(agent: subAgent, settings: settings)
            && depth < AgentRunContext.depthLimit(for: subAgent, settings: settings)
        return all.filter { tool in
            guard tool.isEnabled else { return false }
            if neverAvailable.contains(tool.name) { return false }
            if tool.name == "agent_spawn" && !canRecurse { return false }
            if tool.name == "agent_message" && !subAgent.canCommunicateWithOthers { return false }
            // An empty allowlist means "everything the workspace allows", which is how existing
            // agents are configured; a populated one is a real restriction.
            if !subAgent.allowedToolIds.isEmpty,
               !subAgent.allowedToolIds.contains(tool.id),
               !subAgent.allowedToolIds.contains(tool.name) {
                return false
            }
            return true
        }
    }

    /// Run `objective` to completion, or to the end of its budget.
    @MainActor
    public static func run(
        subAgent: Agent,
        parentAgent: Agent,
        objective: String,
        context: String,
        workspace: Workspace,
        provider: ModelProvider,
        model: ModelInfo,
        depth: Int,
        maxIterations: Int = 8,
        deadlineSeconds: Double = 300,
        isolate: Bool = true,
        onProgress: @MainActor @escaping (String) -> Void = { _ in }
    ) async -> Outcome {
        let started = CFAbsoluteTimeGetCurrent()
        let settings = PersistenceManager.shared.loadSettings()

        // Isolation first: everything below runs against `effectiveWorkspace`, so a failure to
        // isolate must not silently fall back to editing the parent's tree without saying so.
        var worktree: AgentWorktree.Info?
        var isolationNote = ""
        var effectiveWorkspace = workspace
        if isolate {
            do {
                let info = try await AgentWorktree.create(
                    workspacePath: workspace.folderPath,
                    name: "sub-\(subAgent.role)-\(UUID().uuidString.prefix(4))"
                )
                worktree = info
                effectiveWorkspace.folderPath = info.path
                onProgress("Isolated in \(info.branch)")
            } catch {
                isolationNote = """

                (Could not create an isolated worktree — \(error.localizedDescription) \
                Working directly in the workspace, so review its changes before trusting them.)
                """
            }
        }

        var allTools = PersistenceManager.shared.loadTools()
        _ = ToolSchemaCatalog.ensureParityTools(in: &allTools)
        let tools = toolSet(for: subAgent, depth: depth, settings: settings, all: allTools)

        let systemPrompt = """
        \(subAgent.systemPrompt)

        You are \(subAgent.name), a \(subAgent.role) sub-agent working for \(parentAgent.name).
        You are running unattended: nobody is watching, so you cannot ask questions. \
        \(worktree != nil
            ? "You may create, edit, move and delete files inside your working directory, and commit there. Anything else that needs a person's approval — files outside it, launching apps, and similar — will be refused and reported."
            : "Your working directory is the user's own checkout, so changing files there needs a person's approval and will be refused and reported. Read, search, build and report instead.")

        Your working directory is \(effectiveWorkspace.folderPath)\(worktree != nil ? " — an isolated worktree. Changes here do not affect the user's checkout." : ".")

        Do the work with the tools you have. When the objective is met, reply with a short \
        report and make no further tool calls. Do not ask for confirmation; do not describe \
        what you would do instead of doing it.
        """

        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: """
            Objective: \(objective)

            Context from \(parentAgent.name):
            \(context)
            """)
        ]

        var toolCallsMade: [String] = []
        var summary = ""
        var iterations = 0
        var stoppedBecause = "completed"
        var succeeded = true

        await ToolApprovalManager.shared.withUnattendedApprovals {
            while iterations < maxIterations {
                if CFAbsoluteTimeGetCurrent() - started > deadlineSeconds {
                    stoppedBecause = "ran out of time after \(Int(deadlineSeconds))s"
                    succeeded = false
                    break
                }
                iterations += 1

                let box = ConcurrentTextBox()
                let calls = ToolCallBox()
                do {
                    // Named, so a turn queued behind this one on the local engine can say who
                    // it is waiting for.
                    try await LocalGenerationGate.$claimLabel.withValue("sub-agent \(subAgent.name)") {
                        try await ProviderRouter.shared.stream(
                            provider: provider,
                            model: model,
                            systemPrompt: systemPrompt,
                            messages: messages,
                            temperature: subAgent.temperature,
                            maxTokens: subAgent.maxTokens,
                            reasoningEffort: .off,
                            tools: tools
                        ) { chunk in
                            if !chunk.deltaText.isEmpty { box.append(chunk.deltaText) }
                            if !chunk.toolCalls.isEmpty { calls.add(chunk.toolCalls) }
                        }
                    }
                } catch {
                    stoppedBecause = "the model call failed: \(error.localizedDescription)"
                    succeeded = false
                    break
                }

                let text = AssistantContentSanitizer.splitThinking(from: box.text).visible
                let pending = calls.drain()

                if pending.isEmpty {
                    summary = text
                    stoppedBecause = "completed"
                    break
                }

                messages.append(ChatMessage(role: .assistant, content: text, toolCalls: pending))
                for call in pending {
                    toolCallsMade.append(call.toolName)
                    onProgress("\(subAgent.name): \(call.toolName)")
                    // The frame is what lets an `agent_spawn` from here know its depth and which
                    // model is really running.
                    let parentSession = AgentRunContext.current?.sessionId ?? ""
                    let frame = AgentRunContext.Frame(provider: provider, model: model, depth: depth, sessionId: parentSession)
                    // Unattended: whatever would ask a person is refused and recorded, except edits
                    // inside this sub-agent's own worktree (see `SubAgentToolPolicy`).
                    if let reason = SubAgentToolPolicy.approvalReason(
                        toolName: call.toolName,
                        argumentsJson: call.argumentsJson,
                        worktreePath: worktree?.path,
                        settings: settings,
                        sessionId: parentSession,
                        workspaceRoot: effectiveWorkspace.folderPath
                    ) {
                        _ = await ToolApprovalManager.shared.requestApproval(
                            callId: call.id, toolName: call.toolName, argumentsJson: call.argumentsJson, reason: reason
                        )
                        messages.append(ChatMessage(
                            id: call.id,
                            role: .tool,
                            content: "Refused: \(reason) Sub-agents run unattended, so nobody can approve it. Do not retry it; continue without it and say in your report that it was skipped."
                        ))
                        continue
                    }
                    let result = await AgentRunContext.$current.withValue(frame) {
                        await ToolExecutionEngine.shared.execute(
                            toolName: call.toolName,
                            argumentsJson: call.argumentsJson,
                            workspace: effectiveWorkspace,
                            currentAgent: subAgent,
                            callId: call.id
                        )
                    }
                    messages.append(ChatMessage(
                        id: call.id,
                        role: .tool,
                        content: ToolBounds.boundResult(AgentRunner.describeToolResult(result)).text,
                        attachments: result.producedImages.map {
                            MessageAttachment(
                                name: ($0 as NSString).lastPathComponent,
                                path: $0,
                                sizeBytes: ImageTransport.fileSize(atPath: $0),
                                mimeType: "image/png"
                            )
                        }
                    ))
                }

                if iterations >= maxIterations {
                    stoppedBecause = "hit its \(maxIterations)-step budget"
                    succeeded = false
                    summary = text
                }
            }
        }

        let refused = ToolApprovalManager.shared.refusedWhileUnattended.map {
            "\($0.toolName) — \($0.reason)"
        }
        let changed = await changedFiles(in: effectiveWorkspace.folderPath)

        // A worktree with nothing in it is clutter: every delegation used to leave a directory
        // and an `…/sub-<role>-xxxx` branch behind, including read-only research. Remove it when
        // the sub-agent neither changed a file nor committed. Anything with work in it stays, and
        // the report says where.
        if let info = worktree, changed.isEmpty {
            let commits = await commitsAhead(of: info.head, in: info.path)
            if commits == 0, await removeWorktree(info, workspacePath: workspace.folderPath) {
                worktree = nil
            }
        }

        return Outcome(
            succeeded: succeeded,
            summary: summary + isolationNote,
            toolCallsMade: Array(NSOrderedSet(array: toolCallsMade)).compactMap { $0 as? String },
            filesChanged: changed,
            refusedActions: refused,
            worktreePath: worktree?.path,
            branch: worktree?.branch,
            iterations: iterations,
            stoppedBecause: stoppedBecause,
            durationMs: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
    }

    /// Commits on the worktree's branch since it was created. nil when git cannot say, which is
    /// treated as "keep it".
    public static func commitsAhead(of base: String, in path: String) async -> Int? {
        guard !base.isEmpty,
              let out = try? await AgentWorktree.git(["rev-list", "--count", "\(base)..HEAD"], in: URL(fileURLWithPath: path)) else {
            return nil
        }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func removeWorktree(_ info: AgentWorktree.Info, workspacePath: String) async -> Bool {
        let slug = URL(fileURLWithPath: info.path).lastPathComponent
        guard (try? await AgentWorktree.remove(workspacePath: workspacePath, name: slug, force: false)) != nil else {
            return false
        }
        if let root = try? await AgentWorktree.repositoryRoot(containing: workspacePath) {
            _ = try? await AgentWorktree.git(["branch", "-D", info.branch], in: root)
        }
        return true
    }

    /// What the sub-agent actually touched, from git rather than from its own account of itself.
    public static func changedFiles(in path: String) async -> [String] {
        guard let status = try? await AgentWorktree.git(["status", "--porcelain"], in: URL(fileURLWithPath: path)) else {
            return []
        }
        return status
            .split(separator: "\n")
            .map { String($0.dropFirst(3)) }
            .filter { !$0.isEmpty }
    }
}

/// Tool calls arriving from a stream that is not main-actor isolated.
public final class ToolCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCallInfo] = []
    public func add(_ new: [ToolCallInfo]) {
        lock.lock(); defer { lock.unlock() }
        for call in new where !calls.contains(where: { $0.id == call.id }) {
            calls.append(call)
        }
    }
    public func drain() -> [ToolCallInfo] {
        lock.lock(); defer { lock.unlock() }
        let out = calls; calls = []; return out
    }
}
