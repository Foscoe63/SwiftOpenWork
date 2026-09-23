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
        /// Paths the sub-agent tried to write and was refused, so its report can be checked
        /// against them.
        public var refusedWritePaths: [String] = []
        public var worktreePath: String?
        public var branch: String?
        /// The commit the worktree started from. When the parent had uncommitted changes this is
        /// a snapshot of them, so the sub-agent's own work is the diff against it, not against main.
        public var baseCommit: String? = nil
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
                // A lead that received this list once said nothing about it and moved on to the
                // next task; the five edited files sat on a branch the user never heard of.
                if let branch {
                    lines.append("These changes are only on branch `\(branch)`, not in the user's checkout. "
                        + "Tell the user they exist and where; do not describe them as applied, and merge only if asked.")
                    if let baseCommit, let worktreePath {
                        lines.append("Its own edits alone: `git -C \(worktreePath) diff \(baseCommit)`.")
                    }
                    // After a timeout the lead re-delegated the same work from scratch, and the second
                    // sub-agent never saw the first one's five edited files.
                    if !succeeded {
                        lines.append("It did not finish. A new agent_spawn starts from the user's checkout and will not see this work; "
                            + "delegate the remaining part as a smaller task, or report this branch to the user.")
                    }
                }
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
            // A research sub-agent had its report file refused and still wrote "Report Location:
            // …/deep_analysis_report.md"; the lead passed that on and the user went looking for a
            // file that was never written. Its account is checked against what was refused.
            let phantom = Self.mentionedRefusedWrites(in: trimmed, refused: refusedWritePaths)
            if !phantom.isEmpty {
                lines.append("Warning: its report mentions " + phantom.map { "`\($0)`" }.joined(separator: ", ")
                    + ", but writing that was refused — the file was not created. Do not tell the user it exists.")
            }
            // Its account, not a fact. A research sub-agent reported "no unit tests visible" in a
            // project with a test target, and the lead relayed it to the user as a finding.
            if !trimmed.isEmpty {
                lines.append("\nIts report (its own account: check any claim you act on or repeat to the user):\n\(trimmed)")
            }
            return lines.joined(separator: "\n")
        }

        /// Refused write targets the report names, by path or file name.
        public static func mentionedRefusedWrites(in report: String, refused: [String]) -> [String] {
            var seen = Set<String>()
            return refused.filter { path in
                let name = (path as NSString).lastPathComponent
                guard !name.isEmpty, seen.insert(path).inserted else { return false }
                return report.contains(path) || report.contains(name)
            }
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
                let seed = await AgentWorktree.seedWithUncommittedChanges(
                    worktree: info, workspacePath: workspace.folderPath
                )
                var seeded = info
                seeded.head = seed.head
                worktree = seeded
                effectiveWorkspace.folderPath = info.path
                if let problem = seed.problem {
                    isolationNote = """

                    (The isolated worktree does not fully match the user's checkout: \(problem). \
                    Its edits may not apply cleanly to their current files.)
                    """
                }
                onProgress("Isolated in \(info.branch)" + (seed.copiedChanges ? " with your uncommitted changes" : ""))
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

        Your budget is \(maxIterations) steps and \(Int(deadlineSeconds / 60)) minutes; when it runs out you are \
        stopped mid-task. Find code with grep before reading it, and read large files in windows \
        with offset and limit — reading whole files is what uses the time up. If the objective is \
        bigger than the budget, do the first complete piece and say what is left.
        """

        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: """
            Objective: \(objective)

            Context from \(parentAgent.name):
            \(context)
            """)
        ]

        var toolCallsMade: [String] = []
        var refusedWritePaths: [String] = []
        // Same breaker as the lead's loop. A sub-agent had none, and one spent its whole budget
        // re-reading files it had already read.
        var identicalCalls: [String: Int] = [:]
        var lastText = ""
        var summary = ""
        var iterations = 0
        var stoppedBecause = "completed"
        var succeeded = true
        // The deadline counts the sub-agent's own work, not time queued behind other generations
        // on the local engine. Parallel sub-agents on the built-in model take turns, and one spent
        // most of its 600s waiting for a sibling and was stopped having done little but read.
        let queueWait = LocalGenerationGate.WaitClock()
        let worked = { CFAbsoluteTimeGetCurrent() - started - queueWait.seconds }
        let outOfTime = {
            let waited = Int(queueWait.seconds)
            return "ran out of time after \(Int(deadlineSeconds))s"
                + (waited > 0 ? " of work (plus \(waited)s waiting for the local model)" : "")
        }

        await ToolApprovalManager.shared.withUnattendedApprovals {
            while iterations < maxIterations {
                if worked() > deadlineSeconds {
                    stoppedBecause = outOfTime()
                    succeeded = false
                    // What it last said is the only account of where it got to; the report was
                    // empty on a timeout, so the lead learned nothing about the work it had done.
                    summary = lastText
                    break
                }
                iterations += 1

                let box = ConcurrentTextBox()
                let calls = ToolCallBox()
                // The deadline was only checked between rounds, so one slow round ran a sub-agent
                // to 759s against a 600s limit. The round in flight is now cancelled at the deadline.
                let requestMessages = messages
                let round = Task {
                    // Named, so a turn queued behind this one on the local engine can say who
                    // it is waiting for.
                    try await LocalGenerationGate.$waitClock.withValue(queueWait) {
                        try await LocalGenerationGate.$claimLabel.withValue("sub-agent \(subAgent.name)") {
                            try await ProviderRouter.shared.stream(
                                provider: provider,
                                model: model,
                                systemPrompt: systemPrompt,
                                messages: requestMessages,
                                temperature: subAgent.temperature,
                                maxTokens: subAgent.maxTokens,
                                reasoningEffort: .off,
                                tools: tools
                            ) { chunk in
                                if !chunk.deltaText.isEmpty { box.append(chunk.deltaText) }
                                if !chunk.toolCalls.isEmpty { calls.add(chunk.toolCalls) }
                            }
                        }
                    }
                }
                // Time queued for the engine does not count, so the watchdog re-arms for whatever
                // the queue added while it slept instead of cancelling a round still waiting its turn.
                let watchdog = Task {
                    while !Task.isCancelled {
                        let remaining = deadlineSeconds - worked()
                        if remaining <= 0 { round.cancel(); return }
                        try? await Task.sleep(nanoseconds: UInt64(max(1, remaining) * 1_000_000_000))
                    }
                }
                do {
                    try await round.value
                    watchdog.cancel()
                } catch {
                    watchdog.cancel()
                    if worked() >= deadlineSeconds - 1 {
                        stoppedBecause = outOfTime()
                        succeeded = false
                        let partial = AssistantContentSanitizer.splitThinking(from: box.text).visible
                        summary = partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lastText : partial
                        break
                    }
                    stoppedBecause = "the model call failed: \(error.localizedDescription)"
                    succeeded = false
                    break
                }

                let text = AssistantContentSanitizer.splitThinking(from: box.text).visible
                let pending = calls.drain()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = text }

                if pending.isEmpty {
                    summary = text
                    stoppedBecause = "completed"
                    break
                }

                messages.append(ChatMessage(role: .assistant, content: text, toolCalls: pending))
                var repeatedOut = false
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
                        if let path = Self.writeTarget(toolName: call.toolName, argumentsJson: call.argumentsJson) {
                            refusedWritePaths.append(path)
                        }
                        messages.append(ChatMessage(
                            id: call.id,
                            role: .tool,
                            content: "Refused: \(reason) Sub-agents run unattended, so nobody can approve it. Do not retry it; continue without it and say in your report that it was skipped."
                        ))
                        continue
                    }
                    let signature = AgentRunner.callSignature(call.toolName, call.argumentsJson)
                    let repeats = (identicalCalls[signature] ?? 0) + 1
                    identicalCalls[signature] = repeats
                    if repeats >= 5 {
                        stoppedBecause = "kept repeating the same \(call.toolName) call"
                        succeeded = false
                        summary = lastText
                        repeatedOut = true
                        break
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
                        content: ToolBounds.boundResult(AgentRunner.describeToolResult(result)
                            + (repeats >= 3 ? "\n\n[Stuck breaker] You have made this identical call \(repeats) times; its result has not changed. Use what you have, or finish with your report." : "")).text,
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

                if repeatedOut { break }
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
            refusedWritePaths: refusedWritePaths,
            worktreePath: worktree?.path,
            branch: worktree?.branch,
            baseCommit: worktree?.head,
            iterations: iterations,
            stoppedBecause: stoppedBecause,
            durationMs: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
    }

    /// The file a writing call targets, or nil for any other call.
    public static func writeTarget(toolName: String, argumentsJson: String) -> String? {
        let writers: Set<String> = ["file_write", "edit_file", "multi_edit", "file_copy", "file_move"]
        guard writers.contains(AgentRunner.canonicalToolName(toolName)),
              let data = argumentsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["path", "filename", "filepath", "file", "file_path", "destination", "to"] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Whether the run failed on its first model call, before any tool ran — the model was never
    /// reached, so running it again elsewhere repeats nothing.
    public static func failedBeforeStarting(_ outcome: Outcome) -> Bool {
        !outcome.succeeded
            && outcome.stoppedBecause.hasPrefix("the model call failed")
            && outcome.iterations <= 1
            && outcome.toolCallsMade.isEmpty
            && outcome.filesChanged.isEmpty
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
