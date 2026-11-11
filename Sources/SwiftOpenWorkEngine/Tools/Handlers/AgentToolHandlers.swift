import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Spawning sub-agents and messaging other agents.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let agentToolHandlers: [ToolRegistration] = [
        ToolRegistration(["agent_spawn"]) { await $0.agentSpawnTool($1) },
        ToolRegistration(["agent_message"]) { await $0.agentMessageTool($1) },
    ]

    func agentSpawnTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let currentAgent = call.currentAgent
        let startTime = call.startTime
        let callId = call.callId
        // This used to build a `SubAgentTask` record, return "Spawned sub-agent […] to
        // execute task", and run nothing whatsoever. The task appeared in the Sub-Agent Tree
        // with a progress bar, and no work was ever done. It now runs a real agent.
        let taskTitle = (dict["task_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let taskDesc = dict["task_description"] as? String ?? ""
        let agents = PersistenceManager.shared.loadAgents()
        let teamList = agents.filter { $0.id != currentAgent.id }
            .map { "\($0.id) (\($0.name), \($0.role))" }
            .joined(separator: ", ")

        // No default target. This defaulted to "coder-agent", so a call that forgot the field
        // quietly sent research or review work to the Software Engineer.
        guard let targetAgentId = (dict["target_agent_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetAgentId.isEmpty else {
            return Self.failure("agent_spawn needs target_agent_id. Available: \(teamList)", startTime)
        }
        guard !taskTitle.isEmpty else {
            return Self.failure("agent_spawn needs task_title: the objective, stated so it can be done without questions.", startTime)
        }
        guard let targetAgent = agents.first(where: { $0.id == targetAgentId || $0.name == targetAgentId }) else {
            return Self.failure("No agent '\(targetAgentId)'. Available: \(teamList)", startTime)
        }
        // An agent delegating to itself is a loop with extra steps.
        guard targetAgent.id != currentAgent.id else {
            return Self.failure("An agent cannot spawn itself. Do the work directly, or pick one of: \(teamList)", startTime)
        }

        let spawnSettings = PersistenceManager.shared.loadSettings()
        guard await AgentRunner.subAgentSpawningAllowed(agent: currentAgent, settings: spawnSettings) else {
            return Self.failure(
                "Sub-agent spawning is switched off for \(currentAgent.name) (Settings › Advanced, or the agent's own settings). Do the work directly.",
                startTime
            )
        }

        // Depth comes from the run this call belongs to. Every spawn used to call itself
        // depth 1, so sub-agents could spawn sub-agents without the budget ever applying.
        let parentFrame = AgentRunContext.current
        let depth = (parentFrame?.depth ?? 0) + 1
        let limit = AgentRunContext.depthLimit(for: currentAgent, settings: spawnSettings)
        guard depth <= limit else {
            return Self.failure(
                "Delegation depth limit reached (\(limit)). Do this part directly instead of spawning another agent.",
                startTime
            )
        }

        guard let choice = AgentRunContext.subAgentModel(
            for: targetAgent,
            parent: parentFrame,
            providers: PersistenceManager.shared.loadProviders(),
            settings: spawnSettings
        ) else {
            return Self.failure("No usable provider for the sub-agent.", startTime)
        }

        var task = SubAgentTask(
            parentAgentId: currentAgent.id,
            parentAgentName: currentAgent.name,
            subAgentId: targetAgent.id,
            subAgentName: targetAgent.name,
            subAgentAvatar: targetAgent.avatar,
            taskTitle: taskTitle,
            taskDescription: taskDesc,
            status: .running,
            depth: depth
        )

        // A sub-agent can take minutes. Its steps go to the tool card's live tail, which is
        // otherwise a spinner with no way to tell progress from a hang.
        if let callId { await LiveToolOutput.shared.begin(callId: callId) }
        if let note = choice.note, let callId {
            await LiveToolOutput.shared.append(callId: callId, chunk: note + "\n")
        }
        let budget = SubAgentExecutor.budget(
            requestedSteps: Self.intArgument(dict["max_steps"]),
            settings: spawnSettings
        )
        // Reasoning was forced off for every sub-agent, so the agents doing the hardest,
        // least supervised work did it with the least thought. The lead may ask for a level;
        // otherwise it thinks as hard as the lead, or by its own setting outside a run.
        let effort = SubAgentExecutor.effort(
            requested: dict["effort"] as? String,
            subAgent: targetAgent,
            parent: parentFrame?.reasoningEffort
        )
        let runSubAgent = { (provider: ModelProvider, model: ModelInfo) async -> SubAgentExecutor.Outcome in
            await SubAgentExecutor.run(
                subAgent: targetAgent,
                parentAgent: currentAgent,
                objective: taskTitle,
                context: taskDesc,
                workspace: workspace,
                provider: provider,
                model: model,
                depth: depth,
                maxIterations: budget.steps,
                deadlineSeconds: budget.seconds,
                reasoningEffort: effort,
                onProgress: { line in
                    if let callId { LiveToolOutput.shared.append(callId: callId, chunk: line + "\n") }
                }
            )
        }
        var outcome = await runSubAgent(choice.provider, choice.model)
        var choiceNote = choice.note
        // A provider switched on but not running — Ollama installed, not started — failed the
        // whole delegation on its first call, while one switched *off* fell back to the lead's
        // model. Unreachable is treated like off: once, before any work was done.
        if SubAgentExecutor.failedBeforeStarting(outcome),
           let parent = parentFrame, parent.provider.id != choice.provider.id {
            // `failedBeforeStarting` is any first-call failure — a rejected model or parameter,
            // a missing entitlement, a bad key — not only a server that is down, so say which.
            let unreachable = outcome.stoppedBecause
            if let callId {
                await LiveToolOutput.shared.append(
                    callId: callId,
                    chunk: "\(choice.provider.name) (\(choice.model.id)) failed: \(unreachable). Retrying on \(parent.model.name).\n"
                )
            }
            outcome = await runSubAgent(parent.provider, parent.model)
            choiceNote = "\(targetAgent.name) is configured for \(choice.model.id) on \(choice.provider.name), "
                + "which could not be used (\(unreachable)); it ran on \(parent.model.name) instead."
        }
        if let callId { await LiveToolOutput.shared.finish(callId: callId) }

        task.status = outcome.succeeded ? .completed : .failed
        task.progress = 1.0
        task.resultSummary = outcome.report
        task.completedAt = Date()
        task.durationMs = outcome.durationMs
        if !outcome.succeeded { task.errorMessage = outcome.stoppedBecause }

        let report = choiceNote.map { "\($0)\n\n\(outcome.report)" } ?? outcome.report
        return ToolExecutionResult(
            success: outcome.succeeded,
            output: report,
            error: outcome.succeeded ? nil : outcome.stoppedBecause,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
            createdSubAgentTask: task
        )
    }

    func agentMessageTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let currentAgent = call.currentAgent
        let startTime = call.startTime
        // "Can Communicate with Other Agents" was a toggle in the agent editor that nothing read.
        guard currentAgent.canCommunicateWithOthers else {
            return Self.failure("\(currentAgent.name) is not allowed to message other agents (agent settings).", startTime)
        }
        let content = (dict["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = PersistenceManager.shared.loadAgents()
        let teamList = agents.filter { $0.id != currentAgent.id }
            .map { "\($0.id) (\($0.name))" }
            .joined(separator: ", ")
        // No default recipient. A missing id used to go to `lead-assistant` without a word,
        // so a message meant for a sibling reached nobody who could act on it.
        let requested = ((dict["to_agent_id"] as? String) ?? (dict["to_agent_name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return Self.failure("agent_message needs to_agent_id. Agents: \(teamList)", startTime)
        }
        guard !content.isEmpty else {
            return Self.failure("agent_message needs content: the message itself.", startTime)
        }
        guard let targetAgent = agents.first(where: {
            $0.id == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame
        }) else {
            return Self.failure("No agent '\(requested)'. Agents: \(teamList)", startTime)
        }
        guard targetAgent.id != currentAgent.id else {
            return Self.failure("That is you. Message another agent: \(teamList)", startTime)
        }
        let msg = AgentMessage(
            fromAgentId: currentAgent.id,
            fromAgentName: currentAgent.name,
            toAgentId: targetAgent.id,
            toAgentName: targetAgent.name,
            messageType: .consultation,
            content: content
        )
        let output: String
        if let sessionId = AgentRunContext.current?.sessionId, !sessionId.isEmpty {
            let delivery = AgentMailbox.shared.send(
                sessionId: sessionId,
                toAgentId: targetAgent.id,
                letter: AgentMailbox.Letter(fromAgentId: currentAgent.id, fromAgentName: currentAgent.name, content: content)
            )
            switch delivery {
            case .delivered:
                output = "Delivered to \(targetAgent.name), which is running and will see it at its next step. "
                    + "Replies, if any, arrive the same way; do not wait for one."
            case .held:
                output = "\(targetAgent.name) is not running now. The message is held and will be handed to it "
                    + "if it is spawned later in this chat."
            }
        } else {
            output = "Not delivered: this call is not part of an agent run, so there is no one to receive it."
        }
        // Also returned: `AgentRunner` forwards `createdAgentMessage` to the Agent Messages
        // inspector.
        return ToolExecutionResult(
            success: true,
            output: output,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
            createdAgentMessage: msg
        )
    }
}
