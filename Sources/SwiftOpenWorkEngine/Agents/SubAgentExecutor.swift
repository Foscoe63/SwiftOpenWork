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
        /// `git diff --stat` of its own work, so the lead can judge it without spending a step.
        public var diffStat: String? = nil
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
                    let name = worktreePath.map { ($0 as NSString).lastPathComponent } ?? branch
                    lines.append("These changes are only on branch `\(branch)`, not in the user's checkout. "
                        + "Tell the user they exist and where; do not describe them as applied. "
                        + "When the user wants them, `worktree_merge` with name `\(name)` brings them into the checkout.")
                    if let diffStat, !diffStat.isEmpty {
                        lines.append("Diff:\n" + diffStat)
                    }
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
    /// belongs to the turn the user is in. `worktree_merge` writes into the user's checkout, which
    /// is the lead's call to make with the user, never a sub-agent's. `agent_spawn` is gated
    /// separately, by depth.
    public static let neverAvailable: Set<String> = ["ask_user", "exit_plan_mode", "worktree_merge"]

    /// The most steps a lead can ask for in one `agent_spawn`.
    public static let maxRequestableSteps = 50

    /// Steps and working time for one sub-agent. Without a request it gets the settings. A lead
    /// may ask for more, up to three times the setting (and never past `maxRequestableSteps`),
    /// and the time limit grows with the steps, up to an hour: eight steps was too few for
    /// anything bigger than a one-file change, and there was no way to ask for more.
    public static func budget(requestedSteps: Int?, settings: AppSettings) -> (steps: Int, seconds: Double) {
        let base = max(1, settings.subAgentStepBudget)
        let minutes = Double(max(1, settings.subAgentTimeoutMinutes))
        guard let requested = requestedSteps, requested > 0 else { return (base, minutes * 60) }
        let steps = min(requested, min(maxRequestableSteps, base * 3))
        let scaled = steps > base ? min(60, minutes * Double(steps) / Double(base)) : minutes
        return (steps, max(minutes, scaled) * 60)
    }

    /// The reasoning effort a sub-agent runs with: what the lead asked for, else what the lead
    /// itself is running with, else the sub-agent's own setting.
    public static func effort(requested: String?, subAgent: Agent, parent: ReasoningEffort?) -> ReasoningEffort {
        let raw = (requested ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let chosen = ReasoningEffort(rawValue: raw == "none" ? "off" : raw) { return chosen }
        return parent ?? subAgent.reasoningEffort
    }

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
               !subAgent.allowedToolIds.contains(tool.name),
               !allowsServer(of: tool, in: subAgent.allowedToolIds, settings: settings) {
                return false
            }
            return true
        }
    }

    /// Whether `agent` may use an MCP tool. Servers are switched on globally in Settings; this is
    /// the per-agent half, so one agent can have a server that another does not. An empty
    /// allowlist admits everything, as it does for built-in tools.
    static func agentAllowsMCP(toolId: String, toolName: String, agent: Agent, settings: AppSettings) -> Bool {
        let allowed = agent.allowedToolIds
        if allowed.isEmpty || allowed.contains(toolId) || allowed.contains(toolName) { return true }
        guard let parsed = MCPNamespacedTool.parse(toolName),
              let server = settings.mcpServers.first(where: { $0.id == parsed.serverId }) else { return false }
        return allowed.contains("mcp_\(server.id)") || allowed.contains("mcp_\(server.name)")
    }

    /// A role profile lists a whole server as `mcp_<server id or name>`; that admits every tool
    /// the server advertises. (Individual MCP tools are matched by their own name above.)
    static func allowsServer(of tool: Tool, in allowed: [String], settings: AppSettings) -> Bool {
        guard let parsed = MCPNamespacedTool.parse(tool.name),
              let server = settings.mcpServers.first(where: { $0.id == parsed.serverId }) else { return false }
        return allowed.contains("mcp_\(server.id)") || allowed.contains("mcp_\(server.name)")
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
        reasoningEffort: ReasoningEffort = .off,
        isolate: Bool = true,
        onProgress: @MainActor @escaping (String) -> Void = { _ in }
    ) async -> Outcome {
        let started = CFAbsoluteTimeGetCurrent()
        let settings = PersistenceManager.shared.loadSettings()

        // Its inbox for `agent_message`, open while it runs. Messages held for it in this chat —
        // a lead briefing it before the spawn — are delivered on registering. Registered before
        // the worktree is made, so siblings started in the same step can see each other.
        let parentSession = AgentRunContext.current?.sessionId ?? ""
        let mailboxId = parentSession.isEmpty ? nil : AgentMailbox.shared.register(
            sessionId: parentSession, agentId: subAgent.id, agentName: subAgent.name, task: objective
        )
        defer { if let mailboxId { AgentMailbox.shared.unregister(mailboxId) } }

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
        // Servers already connected. Never starts one: a sub-agent must not wait on an `npx`
        // download. Reads run; anything that would change data is refused by the policy below.
        for mcpTool in await MCPClientManager.shared.cachedMcpToolDefs()
        where !allTools.contains(where: { $0.id == mcpTool.id || $0.name == mcpTool.name }) {
            allTools.append(mcpTool)
        }
        let tools = toolSet(for: subAgent, depth: depth, settings: settings, all: allTools)
        let offeredTools = Set(tools.map { AgentRunner.canonicalToolName($0.name) })

        let systemPrompt = """
        \(subAgent.systemPrompt)

        You are \(subAgent.name), a \(subAgent.role) sub-agent working for \(parentAgent.name).
        You are running unattended: nobody is watching, so you cannot ask questions. \
        \(worktree != nil
            ? "You may create, edit, move and delete files inside your working directory, and commit there. Anything else that needs a person's approval — files outside it, launching apps, and similar — will be refused and reported."
            : "Your working directory is the user's own checkout, so changing files there needs a person's approval and will be refused and reported. Read, search, build and report instead.")

        Your working directory is \(effectiveWorkspace.folderPath)\(worktree != nil ? " — an isolated worktree. Changes here do not affect the user's checkout." : ".")
        \(worktree != nil ? "The task below may name the user's checkout, \(workspace.folderPath). Read and edit the same files under your working directory instead, with paths written in full from it." : "")
        \(WorkspaceContext.promptBlock(WorkspaceContext.snapshot(folderPath: effectiveWorkspace.folderPath)))

        Do the work with the tools you have. When the objective is met, reply with a short \
        report and make no further tool calls. Do not ask for confirmation; do not describe \
        what you would do instead of doing it.

        Your budget is \(maxIterations) steps and \(Int(deadlineSeconds / 60)) minutes; when it runs out you are \
        stopped mid-task. Find code with grep before reading it, and read large files in windows \
        with offset and limit — reading whole files is what uses the time up. If the objective is \
        bigger than the budget, do the first complete piece and say what is left.
        """

        let canMessage = offeredTools.contains("agent_message")
        var teamNote = ""
        if canMessage, let mailboxId {
            // Siblings started in the same step have registered by now in practice: each does so
            // before making its worktree, and git runs one command at a time. Best effort; a late
            // one can still be reached by id.
            let others = AgentMailbox.shared.running(in: parentSession, excluding: mailboxId)
                .filter { $0.agentId != parentAgent.id }
            let lines = others.map { "- `\($0.agentId)` (\($0.agentName)): \($0.task.prefix(120))" }
            var alongside = ""
            if !lines.isEmpty {
                alongside = " Running alongside you now:\n" + lines.joined(separator: "\n")
                    + "\nAgree on anything you share with them, such as an interface or a file, rather than guessing."
            }
            teamNote = """


            Reach \(parentAgent.name) (`\(parentAgent.id)`) or another agent with agent_message; messages \
            sent to you arrive at the start of your next step.\(alongside)
            """
        }

        var messages: [ChatMessage] = [
            ChatMessage(role: .user, content: """
            Objective: \(objective)

            Context from \(parentAgent.name):
            \(context)\(teamNote)
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

        let unattendedRun = await ToolApprovalManager.shared.runUnattended {
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

                // Messages from other agents, before it decides its next step.
                if let mailboxId {
                    let letters = AgentMailbox.shared.drain(mailboxId)
                    if !letters.isEmpty {
                        messages.append(ChatMessage(role: .user, content: AgentMailbox.note(for: letters)))
                        onProgress("\(subAgent.name): \(letters.count) message\(letters.count == 1 ? "" : "s") received")
                    }
                }
                // A few large reads used to fill a sub-agent's window with nothing to relieve it.
                // Same rule as the lead: only under real pressure.
                messages = ContextCompactor.foldOldToolResults(
                    messages,
                    pressure: (
                        estimatedTokens: ContextCompactor.estimatedTokens(messages, extraCharacters: systemPrompt.count),
                        windowTokens: model.contextWindow
                    )
                )

                let box = ConcurrentTextBox()
                let calls = ToolCallBox()
                let thinking = AgentThinkingBlockCollector()
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
                                reasoningEffort: reasoningEffort,
                                tools: tools
                            ) { chunk in
                                if !chunk.deltaText.isEmpty { box.append(chunk.deltaText) }
                                if !chunk.toolCalls.isEmpty { calls.add(chunk.toolCalls) }
                                for block in chunk.thinkingBlocks { thinking.add(block) }
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
                    // Cancelling the parent run (Stop) must reach the round in flight.
                    try await withTaskCancellationHandler {
                        try await round.value
                    } onCancel: {
                        round.cancel()
                    }
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
                var pending = calls.drain()
                if pending.isEmpty {
                    // A model whose template the runtime does not recognise writes its calls as
                    // text. Without this, such a sub-agent "completed" having run nothing. Only
                    // a tool it was offered counts.
                    let offeredNames = Set(tools.map(\.name))
                    pending = TextToolCallParser.parse(text) { name in
                        offeredTools.contains(AgentRunner.canonicalToolName(name)) || offeredNames.contains(name)
                    }.map { ToolCallInfo(id: UUID().uuidString, toolName: $0.tool, argumentsJson: $0.args) }
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = text }

                if pending.isEmpty {
                    summary = text
                    stoppedBecause = "completed"
                    break
                }

                // With the model's own thinking for this step, verbatim — see `ThinkingBlock`.
                messages.append(ChatMessage(role: .assistant, content: text, toolCalls: pending, thinkingBlocks: thinking.snapshot()))
                let frame = AgentRunContext.Frame(
                    provider: provider, model: model, depth: depth, sessionId: parentSession,
                    reasoningEffort: reasoningEffort
                )
                // The leading run of offered read-only calls starts together, as the lead's do.
                // Each still passes every check below in order; only its execution comes from here.
                var prefetched: [String: Task<ToolExecutionResult, Never>] = [:]
                let leadingReads = pending.prefix { call in
                    AgentRunner.isParallelSafe(call.toolName)
                        && offeredTools.contains(AgentRunner.canonicalToolName(call.toolName))
                        && SubAgentToolPolicy.approvalReason(
                            toolName: call.toolName,
                            argumentsJson: call.argumentsJson,
                            worktreePath: worktree?.path,
                            settings: settings,
                            sessionId: parentSession,
                            workspaceRoot: effectiveWorkspace.folderPath
                        ) == nil
                }
                if leadingReads.count > 1 {
                    let readWorkspace = effectiveWorkspace
                    for call in leadingReads {
                        let name = call.toolName, args = call.argumentsJson, id = call.id
                        prefetched[id] = Task {
                            await AgentRunContext.$current.withValue(frame) {
                                await ToolExecutionEngine.shared.execute(
                                    toolName: name, argumentsJson: args, workspace: readWorkspace,
                                    currentAgent: subAgent, callId: id
                                )
                            }
                        }
                    }
                }
                defer { prefetched.values.forEach { $0.cancel() } }
                var repeatedOut = false
                for call in pending {
                    toolCallsMade.append(call.toolName)
                    onProgress("\(subAgent.name): \(call.toolName)")
                    // The frame is what lets an `agent_spawn` from here know its depth and which
                    // model is really running.
                    // Only what this sub-agent was offered. The dispatcher resolves aliases and runs
                    // any name it is given, so a "read-only" reviewer could call `edit_file` — which
                    // the worktree policy below then allows — just by naming it.
                    if !offeredTools.contains(AgentRunner.canonicalToolName(call.toolName)) {
                        messages.append(ChatMessage(
                            id: call.id,
                            role: .tool,
                            content: "Error: `\(call.toolName)` is not one of your tools, so it was not run. Your tools: \(tools.map(\.name).sorted().joined(separator: ", ")). Use one of those, or say in your report what you could not do."
                        ))
                        continue
                    }
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
                    let result: ToolExecutionResult
                    if let early = prefetched.removeValue(forKey: call.id) {
                        result = await withTaskCancellationHandler {
                            await early.value
                        } onCancel: {
                            early.cancel()
                        }
                    } else {
                        result = await AgentRunContext.$current.withValue(frame) {
                            await ToolExecutionEngine.shared.execute(
                                toolName: call.toolName,
                                argumentsJson: call.argumentsJson,
                                workspace: effectiveWorkspace,
                                currentAgent: subAgent,
                                callId: call.id
                            )
                        }
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

        // What *this* sub-agent had refused — not the shared list, which parallel sub-agents and
        // any other unattended run also write to.
        let refused = unattendedRun.refused.map {
            "\($0.toolName) — \($0.reason)"
        }
        var changed = await changedFiles(in: effectiveWorkspace.folderPath)
        var diffStat: String?
        if let info = worktree {
            // Its work is committed on its branch, so the branch carries all of it: uncommitted
            // edits in a worktree are invisible to `git log`, lost by `worktree_remove`, and
            // missing from a merge. Its own commits count as its work too, which `git status`
            // alone did not see.
            if !changed.isEmpty {
                await AgentWorktree.commitAll(in: info.path, message: "\(subAgent.name): \(objective.prefix(72))")
            }
            if let own = await filesChanged(since: info.head, in: info.path) { changed = own }
            if !changed.isEmpty {
                diffStat = try? await AgentWorktree.git(["diff", "--stat=100", info.head, "HEAD"], in: URL(fileURLWithPath: info.path))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

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
            diffStat: diffStat,
            iterations: iterations,
            stoppedBecause: stoppedBecause,
            durationMs: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
    }

    /// The file a writing call targets, or nil for any other call.
    public static func writeTarget(toolName: String, argumentsJson: String) -> String? {
        let writers: Set<String> = ["file_write", "edit_file", "multi_edit", "file_copy", "file_move"]
        let canonical = AgentRunner.canonicalToolName(toolName)
        guard writers.contains(canonical),
              let data = argumentsJson.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let dict = ToolCallRepair.normalizeArguments(tool: canonical, parsed)
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

    /// Files that differ between `base` and the worktree's HEAD. Nil when git cannot say.
    static func filesChanged(since base: String, in path: String) async -> [String]? {
        guard !base.isEmpty,
              let out = try? await AgentWorktree.git(["diff", "--name-only", base, "HEAD"], in: URL(fileURLWithPath: path)) else {
            return nil
        }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
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
