import Foundation
import SwiftOpenWorkCore

/// What a finished sub-agent keeps so the lead can continue it later with `agent_spawn`'s
/// `resume_id`, instead of re-delegating from scratch and losing everything it had read.
///
/// In memory only, scoped to the lead's chat session: a resume id from another chat, or from
/// before a restart, is refused with a message saying so. Bounded, so a long chat that spawns
/// many agents does not keep every transcript.
@MainActor
public final class SubAgentSessions {
    public static let shared = SubAgentSessions()

    public struct Saved: Sendable {
        public var id: String
        public var parentSessionId: String
        public var agentId: String
        public var objective: String
        public var messages: [ChatMessage]
        public var worktree: AgentWorktree.Info?
    }

    static let limit = 12
    private var saved: [String: Saved] = [:]
    private var order: [String] = []

    public func save(
        id: String? = nil,
        parentSessionId: String,
        agentId: String,
        objective: String,
        messages: [ChatMessage],
        worktree: AgentWorktree.Info?
    ) -> String {
        let key = id ?? String(UUID().uuidString.prefix(8)).lowercased()
        if saved[key] == nil { order.append(key) }
        saved[key] = Saved(
            id: key, parentSessionId: parentSessionId, agentId: agentId,
            objective: objective, messages: messages, worktree: worktree
        )
        while order.count > Self.limit { saved[order.removeFirst()] = nil }
        return key
    }

    /// The saved session, only if it belongs to this chat.
    public func session(id: String, parentSessionId: String) -> Saved? {
        guard let found = saved[id], found.parentSessionId == parentSessionId else { return nil }
        return found
    }

    public func ids(in parentSessionId: String) -> [String] {
        order.filter { saved[$0]?.parentSessionId == parentSessionId }
    }
}
