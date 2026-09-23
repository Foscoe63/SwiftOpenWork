import Foundation

public struct Session: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var title: String
    public var agentId: String
    public var providerId: String
    public var modelId: String
    public var isArchived: Bool
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var activeSubAgentTasks: [SubAgentTask]
    public var interAgentMessages: [AgentMessage]
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var estimatedCost: Double
    /// Set when this session was branched from another. Optional so sessions saved before forking
    /// existed still decode.
    public var forkedFromSessionId: String?
    /// The message in the parent that this session ends at.
    public var forkedAtMessageId: String?
    /// Sticky checklist from `todo_write` — survives across turns in this session.
    public var todos: [SessionTodoItem]
    /// The conversation as the model last saw it; see `modelHistory()`.
    public var modelContext: ModelContextSnapshot? = nil

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        title: String = "New Session",
        agentId: String = "lead-assistant",
        providerId: String = "",
        modelId: String = "",
        isArchived: Bool = false,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        activeSubAgentTasks: [SubAgentTask] = [],
        interAgentMessages: [AgentMessage] = [],
        totalPromptTokens: Int = 0,
        totalCompletionTokens: Int = 0,
        estimatedCost: Double = 0.0,
        forkedFromSessionId: String? = nil,
        forkedAtMessageId: String? = nil,
        todos: [SessionTodoItem] = []
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.agentId = agentId
        self.providerId = providerId
        self.modelId = modelId
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.activeSubAgentTasks = activeSubAgentTasks
        self.interAgentMessages = interAgentMessages
        self.totalPromptTokens = totalPromptTokens
        self.totalCompletionTokens = totalCompletionTokens
        self.estimatedCost = estimatedCost
        self.forkedFromSessionId = forkedFromSessionId
        self.forkedAtMessageId = forkedAtMessageId
        self.todos = todos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        title = try c.decode(String.self, forKey: .title)
        agentId = try c.decode(String.self, forKey: .agentId)
        providerId = try c.decode(String.self, forKey: .providerId)
        modelId = try c.decode(String.self, forKey: .modelId)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        activeSubAgentTasks = try c.decodeIfPresent([SubAgentTask].self, forKey: .activeSubAgentTasks) ?? []
        interAgentMessages = try c.decodeIfPresent([AgentMessage].self, forKey: .interAgentMessages) ?? []
        totalPromptTokens = try c.decodeIfPresent(Int.self, forKey: .totalPromptTokens) ?? 0
        totalCompletionTokens = try c.decodeIfPresent(Int.self, forKey: .totalCompletionTokens) ?? 0
        estimatedCost = try c.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? 0
        forkedFromSessionId = try c.decodeIfPresent(String.self, forKey: .forkedFromSessionId)
        forkedAtMessageId = try c.decodeIfPresent(String.self, forKey: .forkedAtMessageId)
        todos = try c.decodeIfPresent([SessionTodoItem].self, forKey: .todos) ?? []
        modelContext = try c.decodeIfPresent(ModelContextSnapshot.self, forKey: .modelContext)
    }

    /// What to send the model as this session's history.
    ///
    /// A turn's steps — each assistant step with its calls, each tool result, folded as the loop
    /// folded them — lived only in the loop and were thrown away when it ended; the session kept
    /// just the final reply. So every new message sent a history the local engine's cache had
    /// never seen, and the whole conversation was re-read from the start: "Context cache reset:
    /// history diverged" at the top of every turn, 24K tokens re-read each time. It also meant
    /// the model forgot what its tools had returned one message ago, and re-read the same files.
    ///
    /// The snapshot is used only while the session still begins with exactly the messages it
    /// covers — same ids, same user text. An edit, a fork, a deleted message or a restore falls
    /// back to the plain transcript.
    public func modelHistory() -> [ChatMessage] {
        guard let snapshot = modelContext, snapshot.covers(messages) else { return messages }
        return snapshot.messages + messages.dropFirst(snapshot.coveredMessageIds.count)
    }

    /// Stamp the session as touched now and total its token counts from its messages.
    ///
    /// Neither was ever written: every saved session carried `updatedAt == createdAt` and zero
    /// totals however long it ran, so an export said a four-hour session had used nothing.
    ///
    /// `providers` prices the totals against the session's own model — pass the app's provider
    /// catalog so `estimatedCost` is real. Omitting it (the default) leaves the cost at whatever
    /// it already was, so callers that only care about the token totals need not look up pricing.
    public mutating func recordActivity(at date: Date = Date(), providers: [ModelProvider] = []) {
        updatedAt = date
        totalPromptTokens = messages.reduce(0) { $0 + max(0, $1.promptTokens) }
        totalCompletionTokens = messages.reduce(0) { $0 + max(0, $1.completionTokens) }
        if let model = providers.first(where: { $0.id == providerId })?.models.first(where: { $0.id == modelId }) {
            estimatedCost = Double(totalPromptTokens) / 1000.0 * model.costPer1kPrompt
                + Double(totalCompletionTokens) / 1000.0 * model.costPer1kCompletion
        }
    }

    /// Whether `text` should name a session: its first message that is not a slash command.
    /// A session opened with `/i-have-adhd` was titled "/i-have-adhd" for good.
    public static func isTitleCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("/")
    }
}

/// The model-facing transcript at the end of a turn, and which session messages it stands for.
public struct ModelContextSnapshot: Codable, Hashable, Sendable {
    /// Ids of the session messages, in order, that `messages` replaces.
    public var coveredMessageIds: [String]
    public var messages: [ChatMessage]

    public init(coveredMessageIds: [String], messages: [ChatMessage]) {
        self.coveredMessageIds = coveredMessageIds
        self.messages = messages
    }

    /// Whether `sessionMessages` still starts with what this snapshot was taken from.
    public func covers(_ sessionMessages: [ChatMessage]) -> Bool {
        guard !coveredMessageIds.isEmpty,
              sessionMessages.count >= coveredMessageIds.count,
              sessionMessages.prefix(coveredMessageIds.count).map(\.id) == coveredMessageIds else { return false }
        // User text is what the snapshot must not contradict. A message compacted out of the
        // snapshot has no copy to compare, which is fine: compaction replaced it on purpose.
        let byId = Dictionary(messages.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        for message in sessionMessages.prefix(coveredMessageIds.count) where message.role == .user {
            if let seen = byId[message.id], seen != message.content { return false }
        }
        return true
    }
}
