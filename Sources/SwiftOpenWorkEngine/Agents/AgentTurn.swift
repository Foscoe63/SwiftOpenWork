import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// One turn of the agent loop: a person's message in, the agent's reply out, with as many model
/// steps and tool calls in between as it takes.
///
/// `AgentRunner.run` used to be a single function holding all of this. The turn's state lives here
/// as properties, and each phase is a method: load the tools, build the prompt, then per step
/// stream the model, account for it, gather its tool calls, gate and run each one, and feed the
/// results back.
@MainActor
final class AgentTurn {
    typealias PendingCall = (id: String, tool: String, args: String)

    /// What a step decided about the turn.
    enum StepOutcome { case nextStep, endTurn }

    /// What streaming one model reply left behind for the rest of the step.
    struct StreamedStep {
        /// The turn's text before this step, so the step's own text can be cut out of the whole.
        let turnTextBefore: String
        let messagesForRequest: [ChatMessage]
        let snap: (text: String, reasoning: String, promptTokens: Int, completionTokens: Int)
        let stopper: AgentStreamStopper
        let toolCallCollector: AgentToolCallCollector
        let thinkingCollector: AgentThinkingBlockCollector
    }

    /// What the model is told one tool call did.
    struct CallOutcome {
        var output: String
        var success: Bool
        var error: String?
        var producedImages: [String]
    }

    // MARK: - What the turn was started with

    let session: Session
    let baseAgent: Agent
    let provider: ModelProvider
    let model: ModelInfo
    let workspace: Workspace
    let allAgents: [Agent]
    let onMessageUpdated: (ChatMessage) -> Void
    let onSubAgentTaskCreated: (SubAgentTask) -> Void
    let onSubAgentTaskUpdated: (SubAgentTask) -> Void
    let onInterAgentMessage: (AgentMessage) -> Void
    let onSessionTodosUpdated: (([SessionTodoItem]) -> Void)?
    let onModelContextUpdated: ((ModelContextSnapshot) -> Void)?
    let group: GroupChat.Turn?

    /// `baseAgent`, or in a group chat the same agent told who else is in the room.
    let agent: Agent
    let groupToolless: Bool
    let effectiveReasoningEffort: ReasoningEffort
    let assistantMsgId: String
    let assistantMsg: ChatMessage
    let lastPrompt: String
    let accumulator: AgentStreamAccumulator
    let loadedSettings: AppSettings
    let maxIterations: Int
    let maxTurnTokens: Int

    // MARK: - Set while preparing the turn

    var mailboxId = ""
    var planModeActive = false
    var availableTools: [Tool] = []
    var disabledToolNames: Set<String> = []
    var casualChat = false
    var inventoryPrompt = false
    var mcpTools: [Tool] = []
    var mcpPromptSummary = ""
    var canDelegate = false
    var deferredBuiltIns: [Tool] = []
    var teamSection = ""
    var instructionsSection = ""
    var workspaceSnapshot: WorkspaceContext.Snapshot?
    var workspaceSection = ""
    var skillsSection = ""
    var workingMessages: [ChatMessage] = []
    var currentRequestId: String?
    var systemPromptWithTools = ""

    // MARK: - Running state of the loop

    var iteration = 0
    // The last step's reply, when the turn ended on an answer rather than on tool calls.
    var finalStepText: String?

    var turnPromptTokens = 0
    var lastStepPrompt = 0
    // What the composer's Sent / Recv show: reported usage, or an estimate where none came.
    var shownPromptTokens = 0
    var shownCompletionTokens = 0
    var turnCompletionTokens = 0
    var identicalToolCounts: [String: Int] = [:]
    /// Signatures of calls parsed from the model's text and already sent to run this turn.
    var textCallsAlreadyRun = Set<String>()
    var askUserStreak = 0
    var halted = false
    var finishedNaturally = false
    // Set when a tool result this iteration marked settled progress — a green test run, a
    // clean tree — which is the cheapest moment to compact.
    var reachedMilestoneThisIteration = false
    // Consecutive MCP results that will not finish the job by being retried. Escalates to a
    // nudge, then to pulling MCP out of the tool list for the rest of the turn.
    var mcpDeadEnds = 0
    var warnedMcpStall = false
    /// Consecutive failures per (tool, arguments) pair, for `identicalFailureLimit`.
    var repeatedFailures: [String: Int] = [:]
    /// Failures on a path that does not exist, by (tool, path) — arguments other than the path
    /// ignored — with the last error text so a block can repeat its "Did you mean" hint.
    var missingPathFailures: [String: (count: Int, hint: String)] = [:]
    /// Successful file reads this turn, by call signature, for `unchangedReadNote`.
    var readLog: [String: AgentRunner.RecordedRead] = [:]
    var mcpDisabledThisTurn = false

    init(
        session: Session,
        agent baseAgent: Agent,
        provider: ModelProvider,
        model: ModelInfo,
        workspace: Workspace,
        allAgents: [Agent],
        reasoningOverride: ReasoningEffort?,
        onMessageUpdated: @escaping (ChatMessage) -> Void,
        onSubAgentTaskCreated: @escaping (SubAgentTask) -> Void,
        onSubAgentTaskUpdated: @escaping (SubAgentTask) -> Void,
        onInterAgentMessage: @escaping (AgentMessage) -> Void,
        onSessionTodosUpdated: (([SessionTodoItem]) -> Void)?,
        onModelContextUpdated: ((ModelContextSnapshot) -> Void)?,
        group: GroupChat.Turn?
    ) {
        // In a group chat this is one speaker's turn. The speaker is told who else is in the room
        // and how it was addressed; the bubble below is still stamped with the original agent.
        let agent: Agent = {
            guard let group else { return baseAgent }
            var speaker = baseAgent
            speaker.systemPrompt = GroupChat.persona(
                base: baseAgent.systemPrompt,
                names: group.roster,
                self: baseAgent.name,
                role: group.role,
                requestedBy: group.requestedBy
            )
            return speaker
        }()
        // A re-plan turn revises the agent's own notes; it does not act. See `GroupChat.Role`.
        let groupToolless = group.map { !$0.role.usesTools } ?? false
        // The chat composer's "Reasoning" pill overrides the agent's own configured effort for
        // this turn when set; nil (no override) preserves the agent's own setting.
        let effectiveReasoningEffort = reasoningOverride ?? agent.reasoningEffort
        let assistantMsgId = UUID().uuidString
        let assistantMsg = ChatMessage(
            id: assistantMsgId,
            sessionId: session.id,
            role: .assistant,
            content: "",
            agentId: baseAgent.id,
            agentName: baseAgent.name,
            agentAvatar: agent.avatar,
            agentColor: agent.color,
            modelId: model.id,
            providerId: provider.id,
            timestamp: Date(),
            isStreaming: true
        )

        self.session = session
        self.baseAgent = baseAgent
        self.provider = provider
        self.model = model
        self.workspace = workspace
        self.allAgents = allAgents
        self.onMessageUpdated = onMessageUpdated
        self.onSubAgentTaskCreated = onSubAgentTaskCreated
        self.onSubAgentTaskUpdated = onSubAgentTaskUpdated
        self.onInterAgentMessage = onInterAgentMessage
        self.onSessionTodosUpdated = onSessionTodosUpdated
        self.onModelContextUpdated = onModelContextUpdated
        self.group = group
        self.agent = agent
        self.groupToolless = groupToolless
        self.effectiveReasoningEffort = effectiveReasoningEffort
        self.assistantMsgId = assistantMsgId
        self.assistantMsg = assistantMsg
        self.lastPrompt = session.messages.last(where: { $0.role == .user })?.content ?? ""
        self.accumulator = AgentStreamAccumulator(
            initialMessage: assistantMsg,
            onUpdate: onMessageUpdated
        )
        let loadedSettings = PersistenceManager.shared.loadSettings()
        self.loadedSettings = loadedSettings
        self.maxIterations = max(1, loadedSettings.maxAutonomousIterations)
        // 0 means the user turned the budget off.
        self.maxTurnTokens = loadedSettings.maxTurnTokens <= 0 ? Int.max : loadedSettings.maxTurnTokens
    }

    // MARK: - The turn

    func run() async {
        defer {
            // Never leave a bubble stuck on isStreaming after cancel / MCP hang recovery.
            if accumulator.message.isStreaming {
                accumulator.finalize()
            }
        }
        announceStart()

        // Delegation is the model's decision, made with `agent_spawn`.
        //
        // This used to be decided by keywords: any prompt containing "build", "create", "project",
        // "research", "analyze", "agent", "team", "subagent" or "refactor" sent the *whole prompt*
        // to the first two team members at once, before the lead did anything, each with a
        // six-step budget. "Create a note" was enough. On a single local model that meant
        // re-reading the prompt for every agent switch and two budget-starved copies of the same
        // job — a scheduled brief took over ten minutes and its research sub-agent ran out of
        // steps every time. The lead is now told who its team is and delegates a specific
        // sub-task when one is worth handing off; see `teamPromptSection`.

        // This turn's inbox for `agent_message`: sub-agents it spawns can reach it, and it reads
        // what arrived after each round of tool results.
        mailboxId = AgentMailbox.shared.register(
            sessionId: session.id, agentId: baseAgent.id, agentName: baseAgent.name, task: "leading this chat"
        )
        defer { AgentMailbox.shared.unregister(mailboxId) }

        await loadTools()
        await describeMCPTools()
        trimToolsForThisTurn()
        await loadProjectContext()
        guard await prepareTranscript() else { return }

        // Promotion is turn-scoped: a catalog harvested against an earlier server set must not
        // leak into this turn as callable tools that no longer resolve.
        await MCPPromotedToolRegistry.shared.reset(owner: session.id)
        await buildSystemPrompt()

        steps: while iteration < maxIterations {
            switch await runStep() {
            case .nextStep: continue steps
            case .endTurn: break steps
            }
        }

        await finish()
    }

    // MARK: - Preparing the turn

    /// Show the empty bubble and record that the turn began.
    private func announceStart() {
        onMessageUpdated(assistantMsg)

        AuditLog.shared.record(sessionId: session.id, event: "turn_start", fields: [
            "agent": baseAgent.name, "model": model.id, "provider": provider.id,
            "unattended": ToolApprovalManager.shared.isUnattended,
            "approval_level": PersistenceManager.shared.loadSettings().terminalSafetyLevel.rawValue,
            "prompt": AuditLog.scrubbed(lastPrompt),
        ])
        // ai-memory: capture this turn's prompt (opens the session on the first turn).
        AIMemoryHooks.shared.noteUserPrompt(
            sessionId: session.id, cwd: workspace.folderPath, prompt: lastPrompt)
    }

    /// The built-in tools that are switched on, and the MCP tools this agent may use.
    private func loadTools() async {
        planModeActive = loadedSettings.planModeEnabled
        let allCatalogTools = PersistenceManager.shared.loadTools()
        availableTools = allCatalogTools.filter { $0.isEnabled }
        // Switching a tool off in Settings only hid it from the list. The dispatcher resolves
        // aliases and runs any name it is given, so a model that called it anyway — a weaker local
        // model, or a call written as text — got it. Enforced where the call would run.
        // A name counts only if no enabled tool shares its canonical form (`read_file` off must not
        // switch `file_read` off with it).
        disabledToolNames = Set(allCatalogTools.filter { !$0.isEnabled }.map { AgentRunner.canonicalToolName($0.name) })
            .subtracting(allCatalogTools.filter(\.isEnabled).map { AgentRunner.canonicalToolName($0.name) })
        _ = ToolSchemaCatalog.ensureParityTools(in: &availableTools)

        // Casual / inventory turns must not wait on npx cold starts.
        casualChat = MCPClientManager.isCasualChatPrompt(lastPrompt)
        inventoryPrompt = MCPClientManager.isMCPInventoryPrompt(lastPrompt)
        let preferMCP = MCPClientManager.preferredServerIds(
            forPrompt: lastPrompt,
            servers: loadedSettings.mcpServers
        )
        let allMcpTools: [Tool]
        if groupToolless {
            // This speaker gets no tools, so waiting on MCP servers to warm would only delay it.
            allMcpTools = []
        } else if casualChat || inventoryPrompt {
            allMcpTools = await MCPClientManager.shared.cachedMcpToolDefs()
            await MCPClientManager.shared.warmAllInBackground()
        } else if !preferMCP.isEmpty {
            // Brief wait only for the servers the prompt actually needs — no status chip spam.
            allMcpTools = await MCPClientManager.shared.mcpToolDefs(
                preferServerIds: preferMCP,
                perServerTimeout: .seconds(8),
                overallTimeout: .seconds(6),
                blockForWarm: true
            )
        } else {
            // Cache-first: never stall the bubble on every enabled npx server.
            allMcpTools = await MCPClientManager.shared.mcpToolDefs(
                preferServerIds: preferMCP,
                perServerTimeout: .seconds(8),
                overallTimeout: .seconds(6),
                blockForWarm: false
            )
        }



        // Servers are enabled globally; the agent's own list decides which of them it is offered.
        mcpTools = allMcpTools.filter {
            SubAgentExecutor.agentAllowsMCP(toolId: $0.id, toolName: $0.name, agent: agent, settings: loadedSettings)
        }
    }

    /// What the prompt says about MCP, and whether MCP schemas are sent now or on request.
    private func describeMCPTools() async {
mcpPromptSummary = ""
        var deferMCPSchemas = false
        if inventoryPrompt {
            // Inventory: compact status only — no tool dump, no tool calling.
            let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
            let liveLines = reports.map { r -> String in
                let state: String
                if !r.enabled { state = "disabled" }
                else if r.connected { state = "connected (\(r.toolCount) tools)" }
                else if let err = r.error { state = "error: \(err)" }
                else { state = "not connected yet" }
                return "| \(r.name) | `\(r.id)` | \(r.transport) | \(state) |"
            }
            mcpPromptSummary = """

            ### MCP inventory (answer from this only)
            | Server | ID | Transport | Status |
            |--------|----|-----------|--------|
            \(liveLines.isEmpty ? "| _(none configured)_ | | | |" : liveLines.joined(separator: "\n"))

            INVENTORY MODE: Reply with one short markdown table of the servers above. \
            Do not call tools. Do not narrate your plan. Do not invent servers.
            """
            availableTools = []
        } else if !mcpTools.isEmpty {
            if let resources = ToolSchemaCatalog.parityDefaults.first(where: { $0.name == "mcp_resources" }),
               !availableTools.contains(where: { $0.name == resources.name }) {
                availableTools.append(resources)
            }
            deferMCPSchemas = MCPToolSearch.shouldDefer(toolCount: mcpTools.count)
            if !deferMCPSchemas {
                for t in mcpTools {
                    if !availableTools.contains(where: { $0.id == t.id || $0.name == t.name }) {
                        availableTools.append(t)
                    }
                }
            }
            if deferMCPSchemas {
                let listing = MCPToolSearch.listing(tools: mcpTools) { serverId in
                    loadedSettings.mcpServers.first(where: { $0.id == serverId })?.name ?? serverId
                }
                mcpPromptSummary = """

                ### MCP tools (\(mcpTools.count) live) — schemas not loaded
                \(listing)
                Call `mcp_describe` with a tool name or a few keywords to load the schemas you need; the tools it returns are then callable directly as `mcp__SERVER_ID__TOOL_NAME`. Do not guess parameters for a tool you have not described.
                """
            }
            // Compact listing — avoid dumping every tool schema twice into the prompt.
            if !deferMCPSchemas {
                let byServer = Dictionary(grouping: mcpTools) { tool -> String in
                    MCPNamespacedTool.parse(tool.name)?.serverId ?? "mcp"
                }
                let lines = byServer.map { serverId, tools -> String in
                    let serverName = loadedSettings.mcpServers.first(where: { $0.id == serverId })?.name ?? serverId
                    let leafNames = tools.compactMap { MCPNamespacedTool.parse($0.name)?.toolName ?? $0.name }
                        .sorted()
                    let shown = leafNames.prefix(10).joined(separator: ", ")
                    let more = leafNames.count > 10 ? " (+\(leafNames.count - 10) more)" : ""
                    return "- **\(serverName)** (`\(serverId)`): \(shown)\(more)"
                }.sorted()
                mcpPromptSummary = """

                ### MCP tools (\(mcpTools.count) live) — call as `mcp__SERVER_ID__TOOL_NAME`
                \(lines.joined(separator: "\n"))
                Prefer native tool calls. Do not narrate before calling. Servers that expose only `get_tool_definitions` and `call_tool_by_name` need the catalog listed first; their catalog tools then become directly callable.
                """
            }
        } else if !casualChat && !loadedSettings.mcpServers.filter(\.isEnabled).isEmpty {
            mcpPromptSummary = """

            ### MCP
            Enabled servers are still warming. Use built-in tools; do not invent MCP tool names.
            """
        }
    }

    /// Cut the tool list down to what this turn may use: plan mode, group turns, deferred
    /// built-ins, and the agent tools this agent is allowed.
    private func trimToolsForThisTurn() {
        if planModeActive && !inventoryPrompt {
            availableTools = AgentRunner.filterToolsForPlanMode(availableTools)
        }
        if groupToolless { availableTools = [] }

        // Offer the agent tools only to an agent allowed to use them, so the model is not handed
        // a tool whose every call is refused.
        canDelegate = !groupToolless
            && AgentRunner.subAgentSpawningAllowed(agent: agent, settings: loadedSettings)
            && AgentRunContext.depthLimit(for: agent, settings: loadedSettings) >= 1
        // Specialised built-ins are listed by name and loaded on request; see `BuiltInToolSearch`.
        // Skipped when there are no tools to speak of (inventory, group turns) and in plan mode,
        // where the list is already cut down.
        deferredBuiltIns = []
        if !inventoryPrompt && !groupToolless && !planModeActive {
            let split = BuiltInToolSearch.partition(availableTools, prompt: lastPrompt)
            availableTools = split.loaded
            deferredBuiltIns = split.deferred
        }
        let skillsOffered = !inventoryPrompt && !groupToolless
        availableTools.removeAll { tool in
            (tool.name == "tool_describe" && deferredBuiltIns.isEmpty)
                || (tool.name == "skill_load" && !skillsOffered)
                || (tool.name == "agent_spawn" && !canDelegate)
                || (tool.name == "agent_message" && !agent.canCommunicateWithOthers)
        }
        teamSection = (inventoryPrompt || !canDelegate)
            ? ""
            : AgentRunner.teamPromptSection(
                agent: agent, allAgents: allAgents, provider: provider,
                budget: (steps: max(1, loadedSettings.subAgentStepBudget), minutes: max(1, loadedSettings.subAgentTimeoutMinutes))
            )
    }

    /// The repository's own instructions and skills, and where the agent is working.
    private func loadProjectContext() async {
        // Undo is scoped to one turn, so the window opens here rather than at session start.
        if group?.startsTurn ?? true {
            await FileCheckpointStore.shared.beginTurn(label: session.id, session: session.id)
        }
        if let notice = group?.notice { accumulator.appendNotice(notice) }

        // Standing rules that live in the repository itself.
        // Only once the person has seen what the project carries; see `ProjectTrust`.
        let projectMayInstruct = ProjectTrust.mayLoad(workspaceRoot: workspace.folderPath)
        if !projectMayInstruct, case .needsReview(let found) = ProjectTrust.state(workspaceRoot: workspace.folderPath) {
            accumulator.appendNotice("Not reading \(found.summary) from this project until you review it.")
        }
        instructionsSection = (inventoryPrompt || !projectMayInstruct)
            ? ""
            : ProjectInstructions.promptBlock(ProjectInstructions.load(folderPath: workspace.folderPath))

        // Where the agent actually is. Without this it guesses paths and build commands every turn.
        workspaceSnapshot = inventoryPrompt ? nil : WorkspaceContext.snapshot(folderPath: workspace.folderPath)
        workspaceSection = workspaceSnapshot.map { WorkspaceContext.promptBlock($0, includeGit: false) } ?? ""

        let enabledSkills = PersistenceManager.shared.loadSkills().filter { $0.isEnabled && $0.isAllowed(by: agent.allowedSkillIds) }
        skillsSection = ""
        // Skip skills dump on inventory — it only encourages digression.
        if !enabledSkills.isEmpty && !inventoryPrompt {
            let skillLines = enabledSkills.map { skill -> String in
                let body = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = body.isEmpty ? skill.description : String(body.prefix(160))
                return "- **\(skill.name)**: \(preview)"
            }
            skillsSection = """

            ### Active Skills
            Only a short preview is shown. Call `skill_load` with a skill's name to read its full instructions before following it.
            \(skillLines.joined(separator: "\n"))
            """
        }

        // Skills that ship with the repository itself. Read from disk every turn, so editing one
        // takes effect on the next message without an import step.
        if !inventoryPrompt && projectMayInstruct {
            skillsSection += ProjectSkills.promptBlock(
                ProjectSkills.load(workspacePath: workspace.folderPath)
                    .filter { $0.isAllowed(by: agent.allowedSkillIds) }
            )
        }

        // Skills the user installed once for every project (`~/.agents/skills`, `~/.claude/skills`).
        // Not behind the workspace trust gate: they are the user's own, not the repository's.
        if !inventoryPrompt {
            skillsSection += ProjectSkills.globalPromptBlock(
                ProjectSkills.loadGlobal().filter { $0.isAllowed(by: agent.allowedSkillIds) }
            )
        }
    }

    /// The messages the model will read. Returns false when a hook refused the person's message.
    private func prepareTranscript() async -> Bool {
        // Continue from the transcript the model saw last turn, so the local engine's cache
        // extends it instead of re-reading the whole conversation (see `Session.modelHistory`).
        workingMessages = group.map {
            GroupChat.flatten(session.messages, speakerId: baseAgent.id, names: $0.names)
        } ?? session.modelHistory()
        // What the person asked for this turn. The transcript is the whole session, so compaction
        // must be told which request is current or it keeps only the session's first one.
        currentRequestId = workingMessages.last(where: ContextCompactor.isPersonRequest)?.id

        // A bare "Continue" carries no task, and after an agent or model switch the new model has
        // no memory of one: restate the last real request and the open todos so it resumes that
        // work instead of inventing its own.
        if AutoContinuePolicy.isContinuePrompt(lastPrompt),
           let task = session.messages.last(where: { $0.role == .user && !AutoContinuePolicy.isContinuePrompt($0.content) && $0.content.count > 40 }) {
            var note = "[System]: You are resuming interrupted work. The user's task, which you must finish (do not start a different one):\n"
                + String(task.content.prefix(4000))
            let open = session.todos.filter { $0.status != .done }
            if !open.isEmpty {
                note += "\nOpen todos:\n" + open.map { "- [\($0.status.rawValue)] \($0.content)" }.joined(separator: "\n")
            }
            if !session.pinnedFacts.isEmpty {
                note += "\nPinned facts:\n" + session.pinnedFacts.prefix(20).map { "- \($0)" }.joined(separator: "\n")
            }
            // What the interrupted turn already did, so a resume does not re-explore from scratch.
            // Each repeated step re-sends the whole context, so re-reading is the costly mistake.
            let done = session.messages.reversed()
                .first(where: { $0.role == .assistant && !$0.toolCalls.isEmpty })?
                .toolCalls.suffix(30).map { call -> String in
                    let args = call.argumentsJson.replacingOccurrences(of: "\n", with: " ")
                    return "- \(call.toolName) \(args.prefix(100))"
                } ?? []
            if !done.isEmpty {
                note += "\nAlready done in the interrupted turn (do not repeat these reads or listings; use what you already learned):\n"
                    + done.joined(separator: "\n")
            }
            workingMessages.append(ChatMessage(sessionId: session.id, role: .user, content: note))
        }

        // UserPromptSubmit hooks: a hook may refuse the message or hand the model context for it.
        // The context rides as a "[System]:" note, which is dropped from the saved transcript like
        // the loop's other steering, so it is re-derived each turn rather than replayed.
        let promptHooks = await ToolHooks.run(
            .userPromptSubmit, input: ["prompt": lastPrompt],
            workspaceRoot: workspace.folderPath, sessionId: session.id
        )
        for notice in promptHooks.notices { accumulator.appendNotice(notice) }
        if let reason = promptHooks.blockReason {
            accumulator.setHalt(reason: "hook", text: "A hook blocked this message: \(reason)")
            return false
        }
        if !promptHooks.context.isEmpty {
            workingMessages.append(ChatMessage(
                sessionId: session.id, role: .user,
                content: "[System]: Context from the user's hooks for this message:\n" + promptHooks.context.joined(separator: "\n")
            ))
        }
        return true
    }

    private func buildSystemPrompt() async {
        // ai-memory: a pending "where we left off" handoff, served once per session and kept for
        // its later turns. Empty when there is none or ai-memory is not running.
        let handoffSection = await AIMemoryHooks.shared
            .handoff(sessionId: session.id, cwd: workspace.folderPath)
            .map { "\n\($0)\n" } ?? ""

        // System prompt with modern tool-calling instructions (supports both native API tools & markdown ReAct schemas)
        // What this agent actually has: a fixed list named Gmail, Calendar and write tools even when
        // they were switched off or plan mode had removed them, and the model called them anyway.
        let builtInToolList = availableTools
            .map(\.name)
            .filter { !MCPNamespacedTool.isNamespaced($0) }
            .sorted()
            .joined(separator: ", ")
        let stablePrompt: String
        if inventoryPrompt {
            stablePrompt = """
            \(agent.systemPrompt)
            \(mcpPromptSummary)

            Be concise. No tool calls. No planning narration. Answer with one short table only.
            """
        } else if groupToolless {
            // No tool list here: a model told it has tools it does not have writes the calls out
            // as text, and then the room reads a wall of pseudo-JSON from an agent that was only
            // asked its opinion.
            stablePrompt = """
            \(agent.systemPrompt)
            \(workspaceSection)
            \(instructionsSection)

            Reply in prose only, without tool calls. Do not comment on tools or say that you cannot run them.
            """
        } else {
            stablePrompt = """
            \(agent.systemPrompt)
            \(workspaceSection)
            \(instructionsSection)

            You are an advanced, fully autonomous coding, systems, and research agent.
            Built-in tools (prefer native function/tool calling): \(builtInToolList)
            terminal_command/run_command: interactive:true for commands that prompt (answer them with send_input).
            \(mcpPromptSummary)
            \(BuiltInToolSearch.promptSection(deferredBuiltIns))
            \(skillsSection)
            \(teamSection)

            CRITICAL:
            0. When you change code: locate it with grep/glob rather than guessing, then verify with
               build_project (and run_tests when behaviour changed) before saying it is done. A
               compiler error is yours to fix, not to report. If an edit goes wrong, revert_changes
               undoes everything this turn touched.
               For a web UI, compiling is not seeing: start it once with preview_start, then run
               preview_check after each change and fix what its console errors and screenshot show.
               Never start a dev server with terminal_command — it is killed after two minutes.
               Before changing a function's signature or behaviour, find_references shows every
               caller; code_diagnostics checks one edited file in seconds.
            Editing well is most of the job:
               - Read the region immediately before you edit it; file_read prefixes every line with
                 its number and a tab — that prefix is not part of the file, so leave it out of
                 old_string.
               - Keep old_string short (2-6 lines) but unique, copied exactly from what you just read.
                 Use multi_edit for several changes to one file, and file_write only for new files
                 or full rewrites.
               - If an edit fails, the error says where your old_string stopped matching. Re-read that
                 region and copy it — do not retry variations from memory, and do not guess line
                 numbers.
               - If the same error survives two attempts, stop patching. Re-read the error and the
                 surrounding code, and change approach.
               - Swift: "the compiler is unable to type-check this expression in reasonable time"
                 means one expression is too complex. Break it into separate `let` values with
                 explicit types; do not restructure the code around it.
            1. Do not narrate ("I will check…" / "Let me…"). Call the tool immediately, then answer.
               Every tool round re-sends the whole conversation, so rounds are the expensive part:
               when several calls do not depend on each other (reading five files, listing two
               folders, grep plus git_status), issue them all in ONE response instead of one per
               round. Never re-read a file or re-list a folder you already have.
            2. Prefer native tool calls. Markdown fallback only if needed:
            ```tool_call
            {"tool": "file_list", "parameters": {"path": "."}}
            ```
            3. After tools finish, give one clear concise report — no repeated self-talk.
            \(planModeActive ? "\n5. PLAN MODE: do not mutate files or run shell. Propose a plan, then `exit_plan_mode` after approval." : "")
            """
        }
        // What changes between turns goes after the cache boundary.
        let volatilePrompt = [workspaceSnapshot.map { WorkspaceContext.gitLine($0) } ?? "", handoffSection]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        systemPromptWithTools = PromptCache.join(stable: stablePrompt, volatile: volatilePrompt)
    }

    // MARK: - One step

    /// One model reply and whatever it asked for.
    private func runStep() async -> StepOutcome {
        if Task.isCancelled {
            accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
            halted = true
            return .endTurn
        }

        iteration += 1

        await compactContext()
        guard let step = await streamStep() else { return .endTurn }
        if endsAfterStream(step) { return .endTurn }
        if recordUsageAndCheckBudgets(step) { return .endTurn }

        // Inventory questions should be one-shot answers — never enter a tool loop.
        if inventoryPrompt || groupToolless {
            finalStepText = accumulator.stepText(from: step.turnTextBefore.count)
            finishedNaturally = true
            return .endTurn
        }

        let pendingCallsToExecute = await collectToolCalls(step)
        if pendingCallsToExecute.isEmpty {
            return answerOrNudge(step)
        }
        return await runToolCalls(step, pendingCallsToExecute)
    }

    /// Fold and compact the transcript when the context is under pressure or a milestone passed.
    private func compactContext() async {
        // Only under real context pressure: every fold rewrites history, and a local model's
        // KV cache cannot continue through a rewrite, so each one is a full re-read. See
        // `ContextCompactor.foldOldToolResults`.
        workingMessages = ContextCompactor.foldOldToolResults(
            workingMessages,
            pressure: (
                estimatedTokens: ContextCompactor.estimatedTokens(
                    workingMessages, extraCharacters: systemPromptWithTools.count
                ),
                windowTokens: model.contextWindow
            )
        )

        // A milestone reached this iteration — a green build or test run, a clean tree — means
        // the work behind it is settled. Compacting here trades detail for room at the
        // cheapest possible moment, instead of waiting for the token budget to force it at a
        // worse one, mid-task.
        //
        // It does cost one KV cache rebuild: rewriting history is exactly what
        // `MLXSessionReuse` refuses to continue through, and correctly so. The rebuild is over
        // the *compacted* prefix, though, so it is cheaper than the prefill that would have
        // been paid on the uncompacted one — and it happens at a milestone rather than
        // mid-task.
        if loadedSettings.autoCompactContext, reachedMilestoneThisIteration {
            let tokensBefore = ContextCompactor.estimatedTokens(workingMessages)
            let compacted = ContextCompactor.compactAtMilestone(
                workingMessages, currentRequestId: currentRequestId, pinnedFacts: session.pinnedFacts
            )
            workingMessages = compacted.messages
            if compacted.didCompact {
                ContextSavings.shared.recordTokens(
                    sessionId: session.id,
                    savedTokens: tokensBefore - ContextCompactor.estimatedTokens(workingMessages)
                )
                accumulator.appendNotice("Milestone reached — earlier steps compacted.")
            }
        }
        reachedMilestoneThisIteration = false

        if loadedSettings.autoCompactContext {
            let threshold = ContextCompactor.compactionThreshold(
                settingTokens: loadedSettings.contextCompactionThresholdTokens,
                contextWindow: model.contextWindow
            )
            // A local model's account of what is about to be dropped, when the person chose
            // one. Asked only when compaction will actually happen.
            var droppedSummary: String?
            if !loadedSettings.compactionSummarizerModel.isEmpty,
               let dropped = ContextCompactor.messagesToDrop(
                workingMessages, thresholdTokens: threshold,
                currentRequestId: currentRequestId, extraCharacters: systemPromptWithTools.count
               ) {
                droppedSummary = await CompactionSummarizer.summarize(
                    dropped,
                    setting: loadedSettings.compactionSummarizerModel,
                    providers: PersistenceManager.shared.loadProviders()
                )
            }
            let tokensBefore = ContextCompactor.estimatedTokens(workingMessages)
            let compacted = ContextCompactor.compactIfNeeded(
                workingMessages,
                thresholdTokens: threshold,
                currentRequestId: currentRequestId,
                extraCharacters: systemPromptWithTools.count,
                pinnedFacts: session.pinnedFacts,
                summary: droppedSummary
            )
            workingMessages = compacted.messages
            if compacted.didCompact {
                ContextSavings.shared.recordTokens(
                    sessionId: session.id,
                    savedTokens: tokensBefore - ContextCompactor.estimatedTokens(workingMessages)
                )
                accumulator.appendNotice(droppedSummary == nil
                    ? "Context compacted to free tokens."
                    : "Context compacted to free tokens; a local model summarised the dropped steps.")
            }
        }
    }

    /// Send the request and apply the reply as it streams. Nil when the provider failed.
    private func streamStep() async -> StreamedStep? {
        // The tasks below outlive this call's stack frame, so they take values, not `self`.
        let accumulator = self.accumulator
        let provider = self.provider
        let model = self.model
        let agent = self.agent
        let systemPromptWithTools = self.systemPromptWithTools
        let effectiveReasoningEffort = self.effectiveReasoningEffort
        let availableTools = self.availableTools

        // Track newly emitted native tool calls during this single turn.
        // Use a lock-backed collector: onChunk runs off the MainActor, and the previous
        // `Task { @MainActor in nativeEmittedToolCalls.append }` raced so tool calls were
        // often lost — the model looked "stuck" narrating without ever executing.
        let toolCallCollector = AgentToolCallCollector()
        let thinkingCollector = AgentThinkingBlockCollector()
        accumulator.beginIteration()
        let textBridge = AgentStreamTextBridge()
        let turnTextBefore = accumulator.fullText
        let stopper = AgentStreamStopper()
        let breakLoops = loadedSettings.autoLoopBreakerEnabled
        // The check is not free, and running it on every token made its cost grow with the
        // answer. Every pattern it looks for needs dozens of tokens to form, so sampling the
        // tail periodically catches the same loops far earlier than waiting for the stream to
        // end, which is what used to happen.
        let checkEvery = 24
        let sinceLastCheck = StreamTickCounter()

        // Snapshot before the Task exists. Passing `workingMessages` directly would capture
        // the mutable local rather than evaluating it at the call site, and the loop appends
        // to it further down — safe only because the stream is awaited first, which the
        // compiler cannot see and a later edit could quietly break.
        let messagesForRequest = workingMessages

        // One consumer applies the chunks in the order they arrived. A task per chunk made no
        // such promise, so the UI could apply token 12 before token 11 (the reconcile below
        // repaired a wrong length, not a wrong order).
        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: LLMStreamChunk.self)
        let chunkConsumer = Task { @MainActor in
            for await chunk in chunkStream { accumulator.applyChunk(chunk) }
        }

        do {
            let streamTask = Task<Void, Error> {
                try await ProviderRouter.shared.stream(
                    provider: provider,
                    model: model,
                    systemPrompt: systemPromptWithTools,
                    messages: messagesForRequest,
                    temperature: agent.temperature,
                    maxTokens: agent.maxTokens,
                    reasoningEffort: effectiveReasoningEffort,
                    tools: availableTools
                ) { chunk in
                    for tc in chunk.toolCalls {
                        toolCallCollector.add(tc)
                    }
                    for block in chunk.thinkingBlocks {
                        thinkingCollector.add(block)
                    }
                    textBridge.ingest(chunk)
                    let grewText = !chunk.deltaText.isEmpty
                    let grewReasoning = !(chunk.deltaReasoning ?? "").isEmpty
                    if breakLoops, grewText || grewReasoning, sinceLastCheck.tick(every: checkEvery) {
                        if AgentStreamAccumulator.detectsRepetitionLoop(in: textBridge.textTail())
                            || AgentStreamAccumulator.detectsRepetitionLoop(in: textBridge.reasoningTail()) {
                            stopper.stop(reason: "repetition")
                        }
                    }
                    chunkContinuation.yield(chunk)
                }
            }
            stopper.attach(streamTask)
            do {
                // `streamTask` is unstructured, so cancelling this run did not reach it: Stop
                // left the model generating (and billing) until it finished by itself.
                try await withTaskCancellationHandler {
                    try await streamTask.value
                } onCancel: {
                    streamTask.cancel()
                }
            } catch {
                // Cancelling a stream surfaces differently per transport — `CancellationError`
                // in-process, `URLError.cancelled` over HTTP. If we asked for the stop, none of
                // them is a failure, and reporting one would blame the provider for our own
                // decision. Anything else is a real error and rethrows.
                guard stopper.stoppedReason != nil || Task.isCancelled else { throw error }
            }
            chunkContinuation.finish()
            await chunkConsumer.value
        } catch {
            chunkContinuation.finish()
            await chunkConsumer.value
            let snap = textBridge.snapshot()
            accumulator.reconcileFromBridge(
                text: snap.text,
                reasoning: snap.reasoning,
                promptTokens: snap.promptTokens,
                completionTokens: snap.completionTokens
            )
            accumulator.handleError(error)
            return nil
        }

        // Flush / recover MainActor UI updates from stream callbacks
        let snap = textBridge.snapshot()
        accumulator.reconcileFromBridge(
            text: snap.text,
            reasoning: snap.reasoning,
            promptTokens: snap.promptTokens,
            completionTokens: snap.completionTokens
        )
        await Task.yield()

        return StreamedStep(
            turnTextBefore: turnTextBefore,
            messagesForRequest: messagesForRequest,
            snap: snap,
            stopper: stopper,
            toolCallCollector: toolCallCollector,
            thinkingCollector: thinkingCollector
        )
    }

    /// True when the person pressed Stop or the model was cut off for repeating itself.
    private func endsAfterStream(_ step: StreamedStep) -> Bool {
        let turnTextBefore = step.turnTextBefore
        let stopper = step.stopper
        // The user pressed Stop while the model was generating. Say so and end the turn; the
        // partial text is kept, and no tool call from a half-finished step is run.
        if Task.isCancelled, stopper.stoppedReason == nil {
            accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
            halted = true
            return true
        }

        if stopper.stoppedReason != nil || accumulator.isLoopDetected {
            // Say so. A silently truncated repetitive answer looks like the model simply
            // stopped, and the user has no way to know the app cut it off or why.
            accumulator.appendNotice("Stopped: the model was repeating itself.")
            // The repeated text was left as the reply, and nothing said what the turn had
            // done or how to go on: a thirty-minute turn ended on its own looping narration.
            // It moves to Reasoning, and the halt offers Continue from the tool results.
            accumulator.hideTurnNarration(beforeLength: turnTextBefore.count)
            let ran = accumulator.message.toolCalls.count
            accumulator.setHalt(
                reason: "repetition",
                text: "The model started repeating itself, so this turn was cut off"
                    + (ran > 0 ? " after \(ran) tool call(s)" : "")
                    + ". Press Continue to resume from where it got to."
            )
            halted = true
            return true
        }
        return false
    }

    /// Add the step's tokens to the turn's totals. True when a token or cost budget ended the turn.
    private func recordUsageAndCheckBudgets(_ step: StreamedStep) -> Bool {
        let messagesForRequest = step.messagesForRequest
        let snap = step.snap
        // This step's own usage. The message keeps the last value it was given, so when a
        // provider reported nothing for a step, adding the message's figure counted the
        // previous step again.
        // On a local engine with a prefix cache, each step's reported prompt includes the
        // previous steps' text, which was already in the cache and cost nothing to re-read.
        // Only what the step added counts toward the budget, so it caps real work (new reads,
        // new output) and not the number of rounds times the context size.
        if CompactionSummarizer.isLocal(provider.kind), lastStepPrompt > 0, snap.promptTokens >= lastStepPrompt {
            turnPromptTokens += snap.promptTokens - lastStepPrompt
        } else {
            turnPromptTokens += snap.promptTokens
        }
        if snap.promptTokens > 0 { lastStepPrompt = snap.promptTokens }
        turnCompletionTokens += snap.completionTokens
        // Some providers and external agents report no usage at all. The bar then shows an
        // estimate for the step (about four characters a token) rather than a flat zero.
        let requestChars = systemPromptWithTools.count
            + messagesForRequest.reduce(0) { $0 + $1.content.count }
            + availableTools.reduce(0) { $0 + $1.description.count + $1.parametersJsonSchema.count }
        let stepPrompt = snap.promptTokens > 0 ? snap.promptTokens : max(1, requestChars / 4)
        shownPromptTokens += stepPrompt
        shownCompletionTokens += snap.completionTokens > 0
            ? snap.completionTokens
            : TokenAccounting.estimate(accumulator.message.content + (accumulator.message.reasoning ?? ""))
        accumulator.setBilled(prompt: shownPromptTokens, completion: shownCompletionTokens, lastPrompt: stepPrompt)
        if turnPromptTokens + turnCompletionTokens > maxTurnTokens {
            accumulator.setHalt(
                reason: "token_budget",
                text: "Turn token budget exceeded (\(turnPromptTokens + turnCompletionTokens) > \(maxTurnTokens)). Press Continue to resume."
            )
            halted = true
            return true
        }

        let spent = TurnCost.usd(model: model, promptTokens: turnPromptTokens, completionTokens: turnCompletionTokens)
        if TurnCost.exceeds(limit: loadedSettings.maxTurnCostUSD, spent: spent) {
            accumulator.setHalt(
                reason: "cost_budget",
                text: "Turn spend limit reached (\(TurnCost.format(spent)) of \(TurnCost.format(loadedSettings.maxTurnCostUSD))). Press Continue to keep going."
            )
            halted = true
            return true
        }
        return false
    }

    /// The tool calls the step asked for, native or written as text.
    private func collectToolCalls(_ step: StreamedStep) async -> [PendingCall] {
        let turnTextBefore = step.turnTextBefore
        let toolCallCollector = step.toolCallCollector
        // Gather tool calls from either native API streaming or Markdown ReAct fallbacks
        var pendingCallsToExecute: [(id: String, tool: String, args: String)] = []
        let nativeEmittedToolCalls = toolCallCollector.snapshot()

        if !nativeEmittedToolCalls.isEmpty {
            for tc in nativeEmittedToolCalls {
                pendingCallsToExecute.append((id: tc.id, tool: tc.toolName, args: tc.argumentsJson))
            }
        } else {
            let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count))
            let knownMCP = Set((await MCPClientManager.shared.advertisedToolNames()).values.flatMap { $0 })
            var parsedMarkdownCalls = AgentRunner.shared.parseToolCalls(from: newlyGeneratedDelta, knownMCP: knownMCP)
            // Fall back to the whole turn only when this step produced no text at all (the
            // accumulator can be reconciled to a shorter string mid-turn). `fullText` keeps the
            // raw call syntax of every earlier step, so parsing it in any other case replayed
            // calls that had already run — an edit applied twice fails "old_string not found",
            // and a replayed file_write overwrites newer content with older.
            if parsedMarkdownCalls.isEmpty,
               newlyGeneratedDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !accumulator.fullText.isEmpty {
                parsedMarkdownCalls = AgentRunner.shared.parseToolCalls(from: accumulator.fullText, knownMCP: knownMCP)
                    .filter { !textCallsAlreadyRun.contains(AgentRunner.callSignature($0.tool, $0.args)) }
            }
            for parsed in parsedMarkdownCalls {
                textCallsAlreadyRun.insert(AgentRunner.callSignature(parsed.tool, parsed.args))
                pendingCallsToExecute.append((id: UUID().uuidString, tool: parsed.tool, args: parsed.args))
            }
        }
        return pendingCallsToExecute
    }

    /// A step with no tool calls: the answer, an empty reply to retry, or an announced action
    /// the model has to be told to carry out.
    private func answerOrNudge(_ step: StreamedStep) -> StepOutcome {
        let turnTextBefore = step.turnTextBefore
        let nativeEmittedToolCalls = step.toolCallCollector.snapshot()
        let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if newlyGeneratedDelta.isEmpty && nativeEmittedToolCalls.isEmpty {
            // Empty model turn — do not silently finalize an blank streaming bubble.
            if iteration < 2 {
                accumulator.appendNotice("Model returned no tokens; retrying…")
                return .nextStep
            }
            accumulator.setHalt(
                reason: "empty_response",
                text: "The model returned an empty response. Press Continue to try again."
            )
            halted = true
            return .endTurn
        } else {
            // Only text that *ends* on an announced action counts: matching anywhere
            // nudged finished answers ("…now let me know if you'd like changes").
            let hasUnfulfilledActionIntent = AutoContinuePolicy.endsWithUnfulfilledIntent(newlyGeneratedDelta)
                && newlyGeneratedDelta.count < 1200 && iteration < 6

            if hasUnfulfilledActionIntent {
                // No tool is named: this used to point at `call_tool_by_name`, the first MCP
                // tool, or a literal `mcp_call` with `{}`, which failed when no MCP server
                // was connected and steered the model away from the tool it meant.
                let nudgeMsg = ChatMessage(
                    sessionId: session.id,
                    role: .user,
                    content: """
                    [System Command]: You described a next step but did not call a tool. \
                    If you meant to act, call the tool you intended now, with real arguments, \
                    and no more prose first. If you are finished, give the final answer.
                    """
                )
                // What it said goes in first, or the nudge answers a message the model
                // is never shown.
                workingMessages.append(ChatMessage(
                    sessionId: session.id,
                    role: .assistant,
                    content: accumulator.stepText(from: turnTextBefore.count)
                ))
                workingMessages.append(nudgeMsg)
                return .nextStep
            } else {
                finalStepText = accumulator.stepText(from: turnTextBefore.count)
                finishedNaturally = true
                return .endTurn
            }
        }
    }

    // MARK: - Tool calls

    /// Run the step's calls in order and feed the results back.
    private func runToolCalls(_ step: StreamedStep, _ pendingCallsToExecute: [PendingCall]) async -> StepOutcome {
        let turnTextBefore = step.turnTextBefore
        let thinkingCollector = step.thinkingCollector
        // The step as the model produced it: its text, then the calls it made. Results
        // follow, each answering its call by id. This used to be appended *after* the
        // results and held the whole turn's text, so the model read its narration out of
        // order and once more per step.
        workingMessages.append(ChatMessage(
            sessionId: session.id,
            role: .assistant,
            content: accumulator.stepText(from: turnTextBefore.count),
            toolCalls: pendingCallsToExecute.map {
                ToolCallInfo(
                    id: $0.id,
                    toolName: $0.tool,
                    argumentsJson: AgentRunner.sanitizeToolArgumentsJson(toolName: $0.tool, argumentsJson: $0.args)
                )
            },
            // The model's own thinking for this step, verbatim: Claude needs it back with
            // the tool results or its reasoning starts over each round.
            thinkingBlocks: thinkingCollector.snapshot()
        ))
        // Hide "Let me check…" preamble once tools are underway.
        accumulator.hideTurnNarration(beforeLength: turnTextBefore.count)
        // Notes for the model that arise while tools run. They wait until every result is in:
        // a message between a call's results breaks the call/result pairing providers require.
        var notesAfterResults: [ChatMessage] = []
        var prefetched = startLeadingReads(pendingCallsToExecute)
        defer { prefetched.values.forEach { $0.cancel() } }
        for queued in pendingCallsToExecute {
            let stop = await runCall(queued, prefetched: &prefetched, notesAfterResults: &notesAfterResults)
            if stop { return .endTurn }
        }
        finishToolRound(notesAfterResults)
        return .nextStep
    }

    private func startLeadingReads(_ toolQueue: [PendingCall]) -> [String: Task<ToolExecutionResult, Never>] {
        let workspace = self.workspace
        let agent = self.agent
        // Start the leading run of read-only calls together. Each still passes through every
        // guard below in order (approval, repeat breakers, unchanged-read notes) and only its
        // execution is taken from here, so the bookkeeping is the same as a serial run. The run
        // ends at the first call that is not read-only: later reads may depend on its effect.
        //
        // Sub-agents join the run when a step delegates more than one task. Each works in its
        // own worktree, so they cannot write over each other, and three delegations used to
        // take three times as long for no reason. On a local model they stay in order: the
        // engine runs one generation at a time, so starting them together gains nothing.
        var prefetched: [String: Task<ToolExecutionResult, Never>] = [:]
        let spawnsRunTogether = AgentRunner.spawnsRunTogether(toolQueue.map(\.tool), provider: provider)
        var spawnsStarted = 0
        let leadingReads = toolQueue.prefix { call in
            let isSpawn = AgentRunner.canonicalToolName(call.tool) == "agent_spawn"
            if isSpawn {
                guard spawnsRunTogether, spawnsStarted < AgentRunner.maxParallelSubAgents else { return false }
            } else if !AgentRunner.isParallelSafe(call.tool) {
                return false
            }
            let ok = !disabledToolNames.contains(AgentRunner.canonicalToolName(call.tool))
                && AgentRunner.approvalReason(
                    toolName: call.tool,
                    argumentsJson: AgentRunner.sanitizeToolArgumentsJson(toolName: call.tool, argumentsJson: call.args),
                    settings: loadedSettings,
                    sessionId: session.id,
                    workspaceRoot: workspace.folderPath
                ) == nil
            if ok && isSpawn { spawnsStarted += 1 }
            return ok
        }
        if leadingReads.count > 1 {
            let frame = AgentRunContext.Frame(
                provider: provider, model: model, depth: 0, sessionId: session.id,
                reasoningEffort: effectiveReasoningEffort
            )
            for call in leadingReads {
                let args = AgentRunner.sanitizeToolArgumentsJson(toolName: call.tool, argumentsJson: call.args)
                let name = call.tool
                let id = call.id
                // A sub-agent runs for minutes, so its card shows from the start, not only once
                // the ones before it have finished.
                if AgentRunner.canonicalToolName(name) == "agent_spawn" {
                    accumulator.updateToolCall(ToolCallInfo(id: id, toolName: name, argumentsJson: args, status: .running))
                }
                prefetched[id] = Task {
                    await AgentRunContext.$current.withValue(frame) {
                        await ToolExecutionEngine.shared.execute(
                            toolName: name,
                            argumentsJson: args,
                            workspace: workspace,
                            currentAgent: agent,
                            callId: id
                        )
                    }
                }
            }
        }
        return prefetched
    }

    /// One call, from its gates to the result message. True when the turn has to stop.
    private func runCall(
        _ queued: PendingCall,
        prefetched: inout [String: Task<ToolExecutionResult, Never>],
        notesAfterResults: inout [ChatMessage]
    ) async -> Bool {
        let callId = queued.id
        let toolName = queued.tool
        var argsJson = AgentRunner.sanitizeToolArgumentsJson(
            toolName: toolName,
            argumentsJson: queued.args
        )

        do {
            try Task.checkCancellation()
        } catch {
            accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
            halted = true
            return true
        }

        var callInfo = ToolCallInfo(
            id: callId,
            toolName: toolName,
            argumentsJson: argsJson,
            status: .running
        )

        guard await passesGates(callId: callId, toolName: toolName, argsJson: argsJson, callInfo: &callInfo) else {
            return false
        }
        guard let stuckNudge = repeatNudge(toolName: toolName, argsJson: argsJson) else { return true }

        let startTool = CFAbsoluteTimeGetCurrent()
        let outcome = await execute(
            callId: callId, toolName: toolName, argsJson: &argsJson, callInfo: &callInfo, prefetched: &prefetched
        )
        let resultOutput = outcome.output
        let resultSuccess = outcome.success
        let resultError = outcome.error
        let producedImages = outcome.producedImages
        noteReadsAndFailures(callId: callId, toolName: toolName, argsJson: argsJson, outcome: outcome)

        let processed = ToolResultPipeline.process(resultOutput, toolName: toolName, sessionId: session.id)
        if let notice = processed.notice {
            accumulator.appendNotice(notice)
        }

        callInfo.status = resultSuccess ? .success : .error
        callInfo.resultOutput = processed.text + stuckNudge
        callInfo.errorMessage = resultError
        callInfo.durationMs = (CFAbsoluteTimeGetCurrent() - startTool) * 1000
        accumulator.updateToolCall(callInfo)

        noteProgress(toolName: toolName, outcome: outcome)
        await offerToolsTheCallUnlocked(
            toolName: toolName, argsJson: argsJson, outcome: outcome, notesAfterResults: &notesAfterResults
        )

        let toolMsg = ChatMessage(
            id: callId,
            sessionId: session.id,
            role: .tool,
            content: processed.text + stuckNudge,
            // Images the tool produced ride along on the message, so the provider can
            // hand them to the model rather than the model reading a path it cannot open.
            attachments: producedImages.map { path in
                MessageAttachment(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    sizeBytes: ImageTransport.fileSize(atPath: path),
                    mimeType: "image/png"
                )
            }
        )
        workingMessages.append(toolMsg)
        return false
    }

    /// Permission rules, then the person's approval where the call needs one. False when the call
    /// was refused; the refusal is already in the transcript.
    private func passesGates(
        callId: String, toolName: String, argsJson: String, callInfo: inout ToolCallInfo
    ) async -> Bool {
        // A standing deny rule ends the call before anyone is asked about it.
        if let verdict = PermissionRules.verdict(
            toolName: toolName, argumentsJson: argsJson, workspaceRoot: workspace.folderPath
        ), verdict.action == .deny {
            callInfo.status = .error
            callInfo.errorMessage = "Denied by a permission rule."
            AuditLog.shared.toolCall(sessionId: session.id, tool: toolName, argumentsJson: argsJson,
                                     decision: .deniedByRule, success: false, note: verdict.explanation)
            accumulator.addToolCall(callInfo)
            workingMessages.append(ChatMessage(
                id: callId, sessionId: session.id, role: .tool,
                content: "Blocked: \(verdict.explanation) Do not retry this call; choose another approach or say what you could not do."
            ))
            return false
        }

        // Sensitive actions (deleting a file, or shell commands under an "always ask"
        // safety policy) are paused for a real user decision before they touch disk.
        if let reason = AgentRunner.approvalReason(
            toolName: toolName,
            argumentsJson: argsJson,
            settings: loadedSettings,
            sessionId: session.id,
            workspaceRoot: workspace.folderPath
        ) {
            callInfo.status = .waitingApproval
            callInfo.approvalReason = reason
            accumulator.addToolCall(callInfo)

            let outcome = await ToolApprovalManager.shared.requestApproval(
                callId: callId,
                toolName: toolName,
                argumentsJson: argsJson,
                reason: reason
            )

            if outcome != .approved {
                AuditLog.shared.toolCall(
                    sessionId: session.id, tool: toolName, argumentsJson: argsJson,
                    decision: outcome == .refusedUnattended ? .refusedUnattended : .rejected,
                    success: false, note: reason
                )
                // A person saying no and nobody being there to ask are different events.
                // Reporting the second as the first would tell the model the user made a
                // decision they never made.
                let explanation = outcome == .refusedUnattended
                    ? "This run is unattended, so no one can approve \(reason). Do not retry it; finish what you can without this action and state plainly that it was skipped and why."
                    : "Action rejected by the user (\(reason)). Do not retry this exact call; explain the situation or propose an alternative."
                callInfo.status = .error
                callInfo.errorMessage = outcome == .refusedUnattended
                    ? "Skipped: needs approval, and this run is unattended."
                    : "Blocked: the user did not approve this action."
                accumulator.updateToolCall(callInfo)
                let toolMsg = ChatMessage(
                    id: callId,
                    sessionId: session.id,
                    role: .tool,
                    content: explanation
                )
                workingMessages.append(toolMsg)
                return false
            }

            AgentRunner.rememberApprovedFetch(toolName: toolName, argumentsJson: argsJson, sessionId: session.id)
            callInfo.status = .running
            accumulator.updateToolCall(callInfo)
        } else {
            // An upsert: a sub-agent started early already has its card.
            accumulator.updateToolCall(callInfo)
        }
        return true
    }

    /// Counts identical calls. Returns the warning to attach to the result ("" when there is
    /// none), or nil when the call was repeated so often that the turn is halted.
    private func repeatNudge(toolName: String, argsJson: String) -> String? {
        let signature = AgentRunner.callSignature(toolName, argsJson)
        let repeatCount = (identicalToolCounts[signature] ?? 0) + 1
        identicalToolCounts[signature] = repeatCount

        if repeatCount >= 12 {
            accumulator.setHalt(
                reason: "stuck_breaker",
                text: "Identical tool call repeated 12 times (\(toolName)). Press Continue to resume with a new approach."
            )
            halted = true
            return nil
        }

        var stuckNudge = ""
        if repeatCount >= 8 {
            stuckNudge = "\n\n[Stuck breaker] Identical call repeated \(repeatCount) times. Stop looping; change strategy or finish."
        } else if repeatCount >= 5 {
            stuckNudge = "\n\n[Stuck breaker] You've repeated this identical tool call \(repeatCount) times. Try a different approach."
        } else if repeatCount >= 3 {
            stuckNudge = "\n\n[Stuck breaker] Identical tool+args seen \(repeatCount) times — avoid repeating without progress."
        }
        return stuckNudge
    }

    /// Run the call, or refuse it and say why: plan mode, a tool that is off, an unchanged file
    /// already read, a call that has already failed the same way.
    private func execute(
        callId: String,
        toolName: String,
        argsJson: inout String,
        callInfo: inout ToolCallInfo,
        prefetched: inout [String: Task<ToolExecutionResult, Never>]
    ) async -> CallOutcome {
        var resultOutput: String
        var resultSuccess = true
        var resultError: String?
        var producedImages: [String] = []

        if toolName == "ask_user" {
            askUserStreak += 1
            if askUserStreak > 5 {
                resultSuccess = false
                resultError = "ask_user streak capped at 5. Stop asking and proceed with best judgment or finish."
                resultOutput = resultError!
            } else if ToolApprovalManager.shared.isUnattended {
                // A run started from a schedule, Shortcut or Loop has no one to answer.
                // Waiting would hold the run — and the scheduler behind it — forever.
                resultSuccess = false
                resultError = "no one is available to answer"
                resultOutput = "Error: this run is unattended, so nobody can answer questions. Do not ask again: choose the most reasonable option yourself, say which you chose, and continue."
            } else {
                let parsed = AgentRunner.parseAskUserArgs(argsJson)
                let answer = await UserChoiceManager.shared.request(
                    question: parsed.question,
                    options: parsed.options,
                    callId: callId
                )
                resultOutput = answer
            }
        } else {
            askUserStreak = 0

            if toolName == "exit_plan_mode" {
                await exitPlanMode()
                resultOutput = "Plan mode exited."
            } else if planModeActive, ToolCallRepair.isBlockedInPlanMode(toolName) {
                // The tool list is filtered in plan mode, but a model can still name a tool
                // it was not offered — and the dispatcher resolves aliases such as `bash`
                // and `write`. Enforce it here, where the call would actually run.
                resultSuccess = false
                resultError = "blocked in plan mode"
                resultOutput = "Error: plan mode is on, so `\(toolName)` (it changes files or runs commands) was not run. Propose your plan, then call `exit_plan_mode` once the user approves."
                accumulator.appendNotice("Blocked `\(toolName)` in plan mode.")
            } else if planModeActive, await AgentRunner.planModeRefusesMCP(
                toolName: toolName, argumentsJson: argsJson, settings: loadedSettings
            ) {
                // The tool list hides MCP writes in plan mode, but a model can still name
                // one, and the approval prompt that would catch it is gone under
                // "Allow Everything". Anything not positively a read is refused here.
                resultSuccess = false
                resultError = "blocked in plan mode"
                resultOutput = "Error: plan mode is on, so `\(toolName)` (an MCP tool that may change data) was not run. Propose your plan, then call `exit_plan_mode` once the user approves."
                accumulator.appendNotice("Blocked `\(toolName)` in plan mode.")
            } else if MCPNamespacedTool.isNamespaced(toolName),
                      !SubAgentExecutor.agentAllowsMCP(toolId: toolName, toolName: toolName, agent: agent, settings: loadedSettings) {
                resultSuccess = false
                resultError = "tool is not enabled for this agent"
                resultOutput = "Error: `\(toolName)` is not enabled for this agent, so it was not run. Use another tool, or tell the user it is unavailable."
                accumulator.appendNotice("Blocked `\(toolName)`: not enabled for this agent.")
            } else if !MCPNamespacedTool.isNamespaced(toolName),
                      disabledToolNames.contains(AgentRunner.canonicalToolName(toolName)) {
                resultSuccess = false
                resultError = "tool is switched off"
                resultOutput = "Error: `\(toolName)` is switched off in Settings → Tools, so it was not run. Use another tool, or tell the user it is unavailable."
                accumulator.appendNotice("Blocked `\(toolName)`: switched off in Settings.")
            } else if let note = AgentRunner.unchangedReadNote(
                toolName: toolName, argumentsJson: argsJson, workspaceRoot: workspace.folderPath,
                log: readLog, transcript: workingMessages
            ) {
                resultOutput = note
                accumulator.appendNotice("Skipped re-reading an unchanged file.")
            } else if let missing = AgentRunner.missingPathKey(toolName, argsJson, workspaceRoot: workspace.folderPath),
                      let prior = missingPathFailures[missing],
                      prior.count >= AgentRunner.identicalFailureLimit {
                // The same nonexistent path with a different offset or limit is not a new
                // attempt. Observed: twelve `file_read` calls on one misspelled path, each
                // varying `offset`, so the identical-call check never matched — while the
                // error text named the right file every time.
                resultSuccess = false
                resultError = "repeated identical call"
                resultOutput = """
                Error: that path does not exist, and it has already failed \(prior.count) times \
                this turn (changing offset or limit does not help). It was not run again.

                \(prior.hint)

                Use the corrected path from the hint above, or `glob` to find the file.
                """
                accumulator.appendNotice("Blocked a repeated call on a missing path (\(toolName)).")
            } else if let priorFailures = repeatedFailures[AgentRunner.callSignature(toolName, argsJson)],
                      priorFailures >= AgentRunner.identicalFailureLimit {
                // Refuse to run a call that has already failed identically.
                //
                // Dead-end detection existed only for MCP (`mcpDeadEnds`), so a
                // first-party tool could fail the same way forever. Observed: a model
                // called `screenshot_window` with identical arguments eight times and was
                // still going when the user stopped it by hand. The model is not being
                // stupid — nothing told it the attempt was hopeless, and "try again" is a
                // reasonable thing to do once.
                resultSuccess = false
                resultError = "repeated identical call"
                resultOutput = """
                Error: this exact call — `\(toolName)` with these exact arguments — has \
                already failed \(priorFailures) times this turn, with the same result each \
                time. It was not run again.

                Nothing has changed that would make it succeed. Either change the \
                arguments, use a different tool, or tell the user what is blocking you and \
                stop. Do not call it again unchanged.
                """
                accumulator.appendNotice("Blocked a repeated failing call to \(toolName).")
            } else {
                let ran = await perform(
                    callId: callId, toolName: toolName, argsJson: &argsJson, callInfo: &callInfo, prefetched: &prefetched
                )
                resultSuccess = ran.success
                resultOutput = ran.output
                resultError = ran.error
                producedImages = ran.producedImages
            }
        }
        return CallOutcome(output: resultOutput, success: resultSuccess, error: resultError, producedImages: producedImages)
    }

    /// Leave plan mode and give the agent back the tools it hid.
    private func exitPlanMode() async {
        planModeActive = false
        var settings = PersistenceManager.shared.loadSettings()
        settings.planModeEnabled = false
        PersistenceManager.shared.saveSettings(settings)
        availableTools = PersistenceManager.shared.loadTools().filter(\.isEnabled)
        _ = ToolSchemaCatalog.ensureParityTools(in: &availableTools)
        for t in mcpTools {
            if !availableTools.contains(where: { $0.id == t.id || $0.name == t.name }) {
                availableTools.append(t)
            }
        }
        // Tools promoted from a meta-tool catalog earlier this turn are still
        // callable; the reload above dropped them from the list.
        for promoted in await MCPPromotedToolRegistry.shared.all(owner: session.id) {
            let server = loadedSettings.mcpServers.first { $0.id == promoted.serverId }
            let effect = MCPEffectCatalog.classifyNested(server: server, nestedToolName: promoted.injectName)
            let model = MCPCatalogPromote.toolModel(for: promoted, effect: effect)
            if !availableTools.contains(where: { $0.name == model.name }) {
                availableTools.append(model)
            }
        }
        // The reload also brought back the agent tools this agent was not offered.
        availableTools.removeAll { tool in
            (tool.name == "agent_spawn" && !canDelegate)
                || (tool.name == "agent_message" && !agent.canCommunicateWithOthers)
        }
        accumulator.appendNotice("Plan mode exited.")
        if let host = EngineHosting.host {
            var liveSettings = host.settings
            liveSettings.planModeEnabled = false
            host.settings = liveSettings
            host.showToast("Plan mode exited")
        }
    }

    /// Hand the call to the tool engine and pass on what it created: messages, sub-agent tasks, todos.
    private func perform(
        callId: String,
        toolName: String,
        argsJson: inout String,
        callInfo: inout ToolCallInfo,
        prefetched: inout [String: Task<ToolExecutionResult, Never>]
    ) async -> CallOutcome {
        var resultSuccess: Bool
        var resultOutput: String
        var resultError: String?
        var producedImages: [String]
        let runFrame = AgentRunContext.Frame(
            provider: provider, model: model, depth: 0, sessionId: session.id,
            reasoningEffort: effectiveReasoningEffort
        )
        let result: ToolExecutionResult
        if let early = prefetched.removeValue(forKey: callId) {
            // The early call runs in its own task, so Stop has to be passed on:
            // a sub-agent started early would otherwise run to its deadline.
            result = await withTaskCancellationHandler {
                await early.value
            } onCancel: {
                early.cancel()
            }
        } else {
            result = await AgentRunContext.$current.withValue(runFrame) {
                await ToolExecutionEngine.shared.execute(
                    toolName: toolName,
                    argumentsJson: argsJson,
                    workspace: workspace,
                    currentAgent: agent,
                    callId: callInfo.id
                )
            }
        }
        resultSuccess = result.success
        resultOutput = AgentRunner.describeToolResult(result)
        resultError = result.error
        producedImages = result.producedImages
        callInfo.fileDiff = result.fileDiff
        callInfo.fileDiffs = result.fileDiffs

        // `agent_message` builds an `AgentMessage` and hands it back here.
        // `ToolExecutionResult.createdAgentMessage` had no reader, so every message
        // the agent sent with that tool was reported as sent and shown nowhere.
        if let sent = result.createdAgentMessage {
            onInterAgentMessage(sent)
        }
        // Same class of bug, one field over: `agent_spawn` returned the task it ran
        // and nothing read it, so a real delegation never reached the Sub-Agent
        // Tree, the message's task cards or the Agent Messages log.
        if let task = result.createdSubAgentTask {
            accumulator.upsertSubAgentTask(task)
            onSubAgentTaskCreated(task)
            onSubAgentTaskUpdated(task)
            onInterAgentMessage(AgentMessage(
                fromAgentId: task.parentAgentId,
                fromAgentName: task.parentAgentName,
                toAgentId: task.subAgentId,
                toAgentName: task.subAgentName,
                messageType: .taskDelegation,
                content: task.taskTitle
            ))
            onInterAgentMessage(AgentMessage(
                fromAgentId: task.subAgentId,
                fromAgentName: task.subAgentName,
                toAgentId: task.parentAgentId,
                toAgentName: task.parentAgentName,
                messageType: .taskResponse,
                content: task.resultSummary
            ))
        }
        if let todos = result.sessionTodos {
            onSessionTodosUpdated?(todos)
        }

        // Dispatcher servers reject `"arguments":"{}"` (a string). Retry once with
        // a real map — but only when the nested target is readable. Substituting a
        // different tool would run something the model never asked for.
        if !resultSuccess,
           toolName.lowercased().contains("call_tool_by_name"),
           let nested = AgentRunner.macUseNestedToolName(from: argsJson),
           (resultOutput + (resultError ?? "")).localizedCaseInsensitiveContains("expected a map")
            || (resultOutput + (resultError ?? "")).localizedCaseInsensitiveContains("invalid type: string") {
            let repaired = MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: nested)
            argsJson = repaired
            callInfo.argumentsJson = repaired
            accumulator.updateToolCall(callInfo)
            accumulator.appendNotice("Retrying `\(nested)` with object `arguments`…")
            let retry = await AgentRunContext.$current.withValue(runFrame) {
                await ToolExecutionEngine.shared.execute(
                    toolName: toolName,
                    argumentsJson: repaired,
                    workspace: workspace,
                    currentAgent: agent,
                    callId: callInfo.id
                )
            }
            resultSuccess = retry.success
            resultOutput = AgentRunner.describeToolResult(retry)
            resultError = retry.error
            producedImages = retry.producedImages
            callInfo.fileDiff = retry.fileDiff
            callInfo.fileDiffs = retry.fileDiffs
        }
        return CallOutcome(output: resultOutput, success: resultSuccess, error: resultError, producedImages: producedImages)
    }

    /// Bookkeeping for the repeat breakers: what was read, and which calls keep failing.
    private func noteReadsAndFailures(callId: String, toolName: String, argsJson: String, outcome: CallOutcome) {
        let resultOutput = outcome.output
        let resultSuccess = outcome.success
        let resultError = outcome.error
        // Remember real reads only; a skipped one points back at the read it stands for.
        if resultSuccess, AgentRunner.canonicalToolName(toolName) == "file_read",
           !resultOutput.hasPrefix("Unchanged since"),
           let path = AgentRunner.readTarget(argumentsJson: argsJson, workspaceRoot: workspace.folderPath) {
            readLog[AgentRunner.callSignature(toolName, argsJson)] = AgentRunner.RecordedRead(
                callId: callId, modified: AgentRunner.modificationDate(path), step: iteration
            )
        }

        // A change to the files ends the sameness. `build_project {}` after an edit is not
        // the same call as `build_project {}` before it, and counting them together halted a
        // fix-build-fix turn at the twelfth build. Only real edits reset the counts; a
        // repeated shell command changes nothing the model can rely on.
        if resultSuccess, AgentRunner.changesFiles(toolName) {
            identicalToolCounts.removeAll()
            repeatedFailures.removeAll()
            missingPathFailures.removeAll()
        }

        // Track identical failures so the branch above can refuse the third one.
        let repeatKey = AgentRunner.callSignature(toolName, argsJson)
        if resultSuccess {
            repeatedFailures[repeatKey] = 0
        } else if resultError != "repeated identical call" {
            repeatedFailures[repeatKey, default: 0] += 1
            if let missing = AgentRunner.missingPathKey(toolName, argsJson, workspaceRoot: workspace.folderPath),
               AgentRunner.isMissingPathFailure(resultOutput + " " + (resultError ?? "")) {
                let hint = AgentRunner.didYouMeanHint(in: resultOutput + " " + (resultError ?? ""))
                missingPathFailures[missing] = ((missingPathFailures[missing]?.count ?? 0) + 1, hint)
            }
        }
    }

    /// Milestones (the cheap moment to compact) and MCP calls that retrying will not fix.
    private func noteProgress(toolName: String, outcome: CallOutcome) {
        let resultOutput = outcome.output
        let resultSuccess = outcome.success
        let resultError = outcome.error
        if ContextCompactor.isMilestone(
            toolName: toolName,
            succeeded: resultSuccess,
            output: resultOutput
        ) {
            reachedMilestoneThisIteration = true
        }

        // Track MCP failures that repeating will not fix. A model that keeps re-sending a
        // broken call burns the whole step budget without noticing.
        let isMCPCall = MCPNamespacedTool.isNamespaced(toolName)
            || toolName == "mcp_call"
            || toolName == "call_mcp_tool"
        if isMCPCall {
            let combined = resultOutput + (resultError ?? "")
            if MCPFailureClassifier.isDeadEnd(combined) {
                mcpDeadEnds += 1
            } else {
                mcpDeadEnds = 0
            }
        }
    }

    /// Tools the call asked to load, or a catalog it returned: callable from the next step.
    private func offerToolsTheCallUnlocked(
        toolName: String, argsJson: String, outcome: CallOutcome, notesAfterResults: inout [ChatMessage]
    ) async {
        let resultOutput = outcome.output
        let resultSuccess = outcome.success
        // Schemas the model asked for: from the next step they are real tools, so it calls
        // them with typed arguments instead of describing them again.
        if resultSuccess, AgentRunner.canonicalToolName(toolName) == "mcp_describe",
           let data = argsJson.data(using: .utf8),
           let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let query = args["query"] as? String ?? args["name"] as? String ?? args["tool"] as? String ?? ""
            let limit = (args["limit"] as? Int) ?? Int(args["limit"] as? String ?? "") ?? MCPToolSearch.defaultLimit
            for tool in MCPToolSearch.match(query: query, in: mcpTools, limit: limit)
            where !availableTools.contains(where: { $0.id == tool.id || $0.name == tool.name })
                && !(planModeActive && tool.requiresApproval) {
                availableTools.append(tool)
            }
        }

        // Same for built-in tools the model asked `tool_describe` to load.
        if resultSuccess, AgentRunner.canonicalToolName(toolName) == "tool_describe",
           let data = argsJson.data(using: .utf8),
           let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let query = args["query"] as? String ?? args["name"] as? String ?? args["tool"] as? String ?? ""
            let limit = (args["limit"] as? Int) ?? Int(args["limit"] as? String ?? "") ?? MCPToolSearch.defaultLimit
            for tool in MCPToolSearch.match(query: query, in: deferredBuiltIns, limit: limit)
            where !availableTools.contains(where: { $0.id == tool.id || $0.name == tool.name })
                && !(planModeActive && ToolCallRepair.isBlockedInPlanMode(tool.name)) {
                availableTools.append(tool)
            }
        }

        // A meta-tool catalog came back: promote its entries to directly callable tools so
        // the next step is one hop instead of a hand-nested dispatcher call.
        if resultSuccess,
           MCPCatalogPromote.isCatalogSource(toolName),
           let parsed = MCPNamespacedTool.parse(toolName),
           let server = loadedSettings.mcpServers.first(where: { $0.id == parsed.serverId }) {
            let dispatcher = AgentRunner.dispatcherToolName(
                for: server,
                among: availableTools,
                fallbackLeaf: parsed.toolName
            )
            let harvested = MCPCatalogPromote.harvest(
                server: server,
                executeTool: dispatcher,
                // Raw, not bounded: the bounded copy is head+tail and no longer parses.
                resultText: resultOutput
            ).filter { MCPToolGate.isToolEnabled(server: server, toolName: $0.injectName) }

            let newcomers = await MCPPromotedToolRegistry.shared.register(harvested, owner: session.id)
            if !newcomers.isEmpty {
                for promoted in newcomers {
                    let effect = MCPEffectCatalog.classifyNested(
                        server: server,
                        nestedToolName: promoted.injectName
                    )
                    let model = MCPCatalogPromote.toolModel(for: promoted, effect: effect)
                    if !availableTools.contains(where: { $0.name == model.name }) {
                        availableTools.append(model)
                    }
                }
                let names = newcomers.prefix(8).map(\.chatName).joined(separator: ", ")
                let more = newcomers.count > 8 ? " (+\(newcomers.count - 8) more)" : ""
                accumulator.appendNotice("Promoted \(newcomers.count) \(server.name) tools to direct calls.")
                notesAfterResults.append(
                    ChatMessage(
                        sessionId: session.id,
                        role: .user,
                        content: """
                        \(newcomers.count) tools on \(server.name) are now directly callable \
                        this turn: \(names)\(more). Call them by exactly those \
                        names, with each tool's own arguments — \
                        do not wrap them in \(dispatcher) again.
                        """
                    )
                )
            }
        }
    }

    /// After every result is in: notes held back, mail from other agents, MCP escalation.
    private func finishToolRound(_ notesAfterResults: [ChatMessage]) {
        workingMessages.append(contentsOf: notesAfterResults)

        // What other agents sent this turn with `agent_message`, after the results so the
        // call/result pairing is intact.
        let letters = AgentMailbox.shared.drain(mailboxId)
        if !letters.isEmpty {
            workingMessages.append(ChatMessage(
                sessionId: session.id,
                role: .user,
                content: AgentMailbox.note(for: letters)
            ))
            accumulator.appendNotice("\(letters.count) message\(letters.count == 1 ? "" : "s") from other agents.")
        }

        // MCP escalation. Repeating a call that cannot succeed is the most common way a turn
        // burns its whole step budget, so warn once, then take the tools away.
        if !warnedMcpStall, mcpDeadEnds >= 3 {
            warnedMcpStall = true
            workingMessages.append(ChatMessage(
                sessionId: session.id,
                role: .user,
                content: """
                [System]: MCP calls have failed \(mcpDeadEnds) times in a row. Stop retrying the \
                same call. Fix the arguments using the recovery hint in the last tool result, \
                use a different enabled server, use a built-in tool, or answer from what you \
                already have.
                """
            ))
        }
        if !mcpDisabledThisTurn, mcpDeadEnds >= 5 {
            mcpDisabledThisTurn = true
            availableTools.removeAll { tool in
                MCPNamespacedTool.isNamespaced(tool.name)
                    || tool.name == "mcp_call"
                    || tool.name == "call_mcp_tool"
            }
            accumulator.appendNotice("MCP tools disabled for this turn after \(mcpDeadEnds) failures.")
            workingMessages.append(ChatMessage(
                sessionId: session.id,
                role: .user,
                content: """
                [System]: MCP tools are disabled for the rest of this turn after \(mcpDeadEnds) \
                consecutive failures. Do not attempt another MCP call. Finish with built-in \
                tools or tell the user plainly which MCP server failed and what it reported.
                """
            ))
        }

        // Do not dump raw tool JSON/text into the user-facing chat bubble.
        // The tool observations are already fed back to the LLM in workingMessages as role: .tool / user observation,
        // allowing the LLM to read the result and write a clean, user-friendly natural language response.
    }

    // MARK: - Ending the turn

    private func finish() async {
        if !halted && !finishedNaturally && iteration >= maxIterations {
            accumulator.setHalt(
                reason: "round_cap",
                text: "Reached the autonomous round cap (\(maxIterations)). Press Continue to keep going from here."
            )
        }

        // The nudges steered this turn only; saved, they were replayed on every later turn.
        var modelContext = AgentRunner.droppingHarnessNudges(workingMessages)
        if let finalStepText {
            modelContext.append(ChatMessage(
                id: assistantMsgId, sessionId: session.id, role: .assistant, content: finalStepText
            ))
        }
        // Not for a group: `modelHistory()` ignores it there, since it is one speaker's view.
        if group == nil { onModelContextUpdated?(ModelContextSnapshot(
            coveredMessageIds: session.messages.map(\.id) + [assistantMsgId],
            messages: modelContext
        )) }

        accumulator.finalize()
        AuditLog.shared.record(sessionId: session.id, event: "turn_end", fields: [
            "reason": accumulator.message.haltReason ?? (finishedNaturally ? "completed" : "incomplete"),
            "prompt_tokens": turnPromptTokens, "completion_tokens": turnCompletionTokens, "iterations": iteration,
            "cost_usd": TurnCost.usd(model: model, promptTokens: turnPromptTokens, completionTokens: turnCompletionTokens),
        ])
        _ = await ToolHooks.run(
            .stop,
            input: ["stop_reason": accumulator.message.haltReason ?? (finishedNaturally ? "end_turn" : "incomplete")],
            workspaceRoot: workspace.folderPath, sessionId: session.id
        )
    }
}
