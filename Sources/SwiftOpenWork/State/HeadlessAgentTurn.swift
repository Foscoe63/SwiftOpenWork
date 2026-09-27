import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

/// Run one agent turn with no one watching.
///
/// A turn started from a Shortcut, Siri or a schedule differs from a chat turn in one way that
/// matters: there is no window, so there is nobody to approve a sensitive tool call. Everything
/// else — the ReAct loop, the tools, the sandbox — is the same machinery, deliberately, because a
/// second execution path would be a second place for behaviour to drift.
///
/// The turn is recorded as a real session so the user can open the app and see exactly what ran on
/// their behalf. An automated action nobody can audit afterwards is worse than one that never ran.
@MainActor
public enum HeadlessAgentTurn {

    public struct Result: Sendable {
        /// What the agent said.
        public var reply: String
        /// Actions it wanted to take but could not, because approving them needs a person.
        public var skipped: [String]
        /// The session this turn was recorded in, so the caller can point the user at it.
        public var sessionId: String

        /// The reply, plus a plain statement of anything skipped.
        ///
        /// Spoken or pasted into a Shortcut, the reply alone would imply the whole job was done.
        /// Saying what was skipped is the whole point of refusing rather than hanging.
        public var spoken: String {
            guard !skipped.isEmpty else { return reply }
            let list = skipped.map { "• \($0)" }.joined(separator: "\n")
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = trimmed.isEmpty ? "The run stopped before it produced an answer." : trimmed
            return """
            \(head)

            Skipped — these need approval, and nothing was watching:
            \(list)
            """
        }
    }

    /// Run `prompt` to completion and return what it said and what it could not do.
    ///
    /// `agentId` names the agent to run. It matters for automations: an automation stores a
    /// `targetAgentId`, and running whichever agent the user last had selected in the window would
    /// quietly execute a scheduled prompt against the wrong system prompt and the wrong tool
    /// allowlist. An unknown or empty id falls back to the current agent, which is what a
    /// Shortcut with no agent named should do.
    public static func run(
        prompt: String,
        title: String,
        appState: AppState,
        agentId: String? = nil,
        workspace workspaceOverride: Workspace? = nil,
        onSessionStarted: ((String) -> Void)? = nil
    ) async -> Result {
        let agent = appState.agents.first { $0.id == agentId } ?? appState.currentAgent
        let provider = appState.currentProvider
        let model = appState.currentModel
        // A loop runs in its own folder, which need not be the one the window has open.
        let workspace = workspaceOverride ?? appState.currentWorkspace

        // Same rule as an on-screen turn: a switched-off local provider must not be replaced by
        // a cloud one. This path matters more, not less — a Shortcut or a Siri phrase runs with
        // nobody watching, so a silent substitution would never be noticed.
        if let resolution = appState.currentProviderResolution, resolution.mustRefuse,
           let reason = resolution.refusalMessage {
            return Result(reply: reason, skipped: [], sessionId: "")
        }

        var session = Session(
            workspaceId: workspace.id,
            title: title,
            agentId: agent.id,
            providerId: provider.id,
            modelId: model.id
        )
        let userMsg = ChatMessage(sessionId: session.id, role: .user, content: prompt)
        session.messages.append(userMsg)

        appState.sessions.insert(session, at: 0)
        PersistenceManager.shared.saveSessions(appState.sessions)

        let sessionId = session.id
        onSessionStarted?(sessionId)
        var reply = ""

        // Visible in the chat header, and named on the local engine's queue. A run nobody started
        // from the window used to leave the header reading "Agent ready" while it held the model,
        // so a chat turn that then sat waiting looked like a hang.
        appState.backgroundRuns.append(BackgroundRun(sessionId: sessionId, title: title))
        defer { appState.backgroundRuns.removeAll { $0.sessionId == sessionId } }

        await ToolApprovalManager.shared.withUnattendedApprovals {
            await LocalGenerationGate.$claimLabel.withValue("background run “\(title)”") {
            await AgentRunner.shared.run(
                session: session,
                agent: agent,
                provider: provider,
                model: model,
                workspace: workspace,
                allAgents: appState.agents,
                onMessageUpdated: { updated in
                    if updated.role == .assistant { reply = updated.content }
                    guard let sIdx = appState.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
                    if let mIdx = appState.sessions[sIdx].messages.firstIndex(where: { $0.id == updated.id }) {
                        appState.sessions[sIdx].messages[mIdx] = updated
                    } else {
                        appState.sessions[sIdx].messages.append(updated)
                    }
                    // Saved as it goes, as a chat turn is. This path saved only at the start and
                    // the end, so a run the app quit during was left on disk as a prompt with no
                    // reply, however much it had done.
                    PersistenceManager.shared.saveSessions(appState.sessions)
                },
                onSubAgentTaskCreated: { _ in },
                onSubAgentTaskUpdated: { _ in },
                onInterAgentMessage: { _ in }
            )
            }
        }

        // An unattended run is the one nobody watched, so it is the one most worth being able
        // to undo afterwards.
        await SessionCheckpointStore.sealCurrentTurn(
            sessionId: sessionId, messageId: userMsg.id, label: title
        )

        let skipped = ToolApprovalManager.shared.refusedWhileUnattended.map {
            "\($0.toolName) — \($0.reason)"
        }

        PersistenceManager.shared.saveSessions(appState.sessions)
        return Result(reply: reply, skipped: skipped, sessionId: sessionId)
    }
}
