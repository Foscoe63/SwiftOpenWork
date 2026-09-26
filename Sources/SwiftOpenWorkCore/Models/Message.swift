import Foundation

public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    case tool = "tool"
}

public struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var sizeBytes: Int64
    public var mimeType: String
    public var previewText: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        sizeBytes: Int64 = 0,
        mimeType: String = "text/plain",
        previewText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.previewText = previewText
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sessionId: String
    public var role: MessageRole
    public var content: String
    public var reasoning: String?
    public var thinkingTimeMs: Double?
    public var agentId: String?
    public var agentName: String?
    public var agentAvatar: String?
    public var agentColor: String?
    public var modelId: String?
    public var providerId: String?
    public var timestamp: Date
    public var toolCalls: [ToolCallInfo]
    public var subAgentTasks: [SubAgentTask]
    public var attachments: [MessageAttachment]
    public var isStreaming: Bool
    public var isError: Bool
    public var promptTokens: Int
    public var completionTokens: Int
    /// Measured decode speed of the reply, when the provider reports one.
    public var generationTokensPerSecond: Double?
    /// Durable harness notices (compaction, tools-unsupported) — Radiant `notice` parts.
    public var notices: [String]
    /// Durable halt reason when a turn was stopped by budget / stuck breaker / round cap.
    public var haltReason: String?
    public var haltText: String?
    /// The provider's own thinking blocks for this reply, verbatim, when it produced any and the
    /// API needs them back (Claude, within a tool-use turn). Nil for every other reply — and for
    /// every message saved before this existed, which decodes to nil.
    public var thinkingBlocks: [ThinkingBlock]?

    public init(
        id: String = UUID().uuidString,
        sessionId: String = "",
        role: MessageRole,
        content: String,
        reasoning: String? = nil,
        thinkingTimeMs: Double? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        agentAvatar: String? = nil,
        agentColor: String? = nil,
        modelId: String? = nil,
        providerId: String? = nil,
        timestamp: Date = Date(),
        toolCalls: [ToolCallInfo] = [],
        subAgentTasks: [SubAgentTask] = [],
        attachments: [MessageAttachment] = [],
        isStreaming: Bool = false,
        isError: Bool = false,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        notices: [String] = [],
        haltReason: String? = nil,
        haltText: String? = nil,
        thinkingBlocks: [ThinkingBlock]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.thinkingTimeMs = thinkingTimeMs
        self.agentId = agentId
        self.agentName = agentName
        self.agentAvatar = agentAvatar
        self.agentColor = agentColor
        self.modelId = modelId
        self.providerId = providerId
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.subAgentTasks = subAgentTasks
        self.attachments = attachments
        self.isStreaming = isStreaming
        self.isError = isError
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.notices = notices
        self.haltReason = haltReason
        self.haltText = haltText
        self.thinkingBlocks = thinkingBlocks
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, reasoning, thinkingTimeMs
        case agentId, agentName, agentAvatar, agentColor, modelId, providerId
        case timestamp, toolCalls, subAgentTasks, attachments
        case isStreaming, isError, promptTokens, completionTokens, generationTokensPerSecond
        case notices, haltReason, haltText, thinkingBlocks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        self.role = try container.decodeIfPresent(MessageRole.self, forKey: .role) ?? .assistant
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        self.thinkingTimeMs = try container.decodeIfPresent(Double.self, forKey: .thinkingTimeMs)
        self.agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        self.agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        self.agentAvatar = try container.decodeIfPresent(String.self, forKey: .agentAvatar)
        self.agentColor = try container.decodeIfPresent(String.self, forKey: .agentColor)
        self.modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        self.providerId = try container.decodeIfPresent(String.self, forKey: .providerId)
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.toolCalls = try container.decodeIfPresent([ToolCallInfo].self, forKey: .toolCalls) ?? []
        self.subAgentTasks = try container.decodeIfPresent([SubAgentTask].self, forKey: .subAgentTasks) ?? []
        self.attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        self.isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        self.generationTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .generationTokensPerSecond)
        self.completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        self.notices = try container.decodeIfPresent([String].self, forKey: .notices) ?? []
        self.haltReason = try container.decodeIfPresent(String.self, forKey: .haltReason)
        self.haltText = try container.decodeIfPresent(String.self, forKey: .haltText)
        self.thinkingBlocks = try container.decodeIfPresent([ThinkingBlock].self, forKey: .thinkingBlocks)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(thinkingTimeMs, forKey: .thinkingTimeMs)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encodeIfPresent(agentName, forKey: .agentName)
        try container.encodeIfPresent(agentAvatar, forKey: .agentAvatar)
        try container.encodeIfPresent(agentColor, forKey: .agentColor)
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encodeIfPresent(providerId, forKey: .providerId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(subAgentTasks, forKey: .subAgentTasks)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(isError, forKey: .isError)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encodeIfPresent(generationTokensPerSecond, forKey: .generationTokensPerSecond)
        try container.encode(notices, forKey: .notices)
        try container.encodeIfPresent(haltReason, forKey: .haltReason)
        try container.encodeIfPresent(haltText, forKey: .haltText)
        try container.encodeIfPresent(thinkingBlocks, forKey: .thinkingBlocks)
    }
}
