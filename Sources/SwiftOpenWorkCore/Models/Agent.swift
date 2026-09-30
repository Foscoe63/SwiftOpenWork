import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case off = "off"

    public var displayName: String {
        switch self {
        case .low: return "Low Effort (Fast)"
        case .medium: return "Medium Effort"
        case .high: return "High Effort (Deep Analysis)"
        case .off: return "Disabled"
        }
    }
}

public struct Agent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var avatar: String
    public var color: String
    public var role: String
    public var systemPrompt: String
    public var providerId: String
    public var modelId: String
    public var temperature: Double
    public var maxTokens: Int
    public var topP: Double
    public var reasoningEffort: ReasoningEffort
    public var parentAgentId: String?
    public var subAgentIds: [String]
    public var allowedToolIds: [String]
    /// Skills this agent is shown, by skill id, name, or `project:<folder>` for a repository skill.
    /// nil or empty means every enabled skill. Optional so agents saved before this existed decode.
    public var allowedSkillIds: [String]?
    public var canSpawnSubAgents: Bool
    public var maxSubAgentDepth: Int
    public var autoDelegate: Bool
    public var canCommunicateWithOthers: Bool
    public var tags: [String]
    public var isBuiltIn: Bool
    public var isLeadAgent: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        avatar: String = "person.crop.circle.badge.checkmark",
        color: String = "#8B5CF6",
        role: String = "General Assistant",
        systemPrompt: String = "You are a helpful, expert AI assistant. Provide concise, high quality and accurate answers.",
        providerId: String = "",
        modelId: String = "",
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        topP: Double = 1.0,
        reasoningEffort: ReasoningEffort = .medium,
        parentAgentId: String? = nil,
        subAgentIds: [String] = [],
        // Empty means "every tool enabled in the workspace". This used to seed a fixed
        // seven-item list written before most of the catalog existed, which nothing read — so
        // the moment anything honoured it, agents would silently lose grep, edit_file,
        // build_project, run_tests and every perception tool. See
        // `PersistenceManager.isLegacySeededAllowlist`.
        allowedToolIds: [String] = [],
        allowedSkillIds: [String]? = nil,
        canSpawnSubAgents: Bool = true,
        maxSubAgentDepth: Int = 3,
        autoDelegate: Bool = true,
        canCommunicateWithOthers: Bool = true,
        tags: [String] = ["General"],
        isBuiltIn: Bool = false,
        isLeadAgent: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.avatar = avatar
        self.color = color
        self.role = role
        self.systemPrompt = systemPrompt
        self.providerId = providerId
        self.modelId = modelId
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.reasoningEffort = reasoningEffort
        self.parentAgentId = parentAgentId
        self.subAgentIds = subAgentIds
        self.allowedToolIds = allowedToolIds
        self.allowedSkillIds = allowedSkillIds
        self.canSpawnSubAgents = canSpawnSubAgents
        self.maxSubAgentDepth = maxSubAgentDepth
        self.autoDelegate = autoDelegate
        self.canCommunicateWithOthers = canCommunicateWithOthers
        self.tags = tags
        self.isBuiltIn = isBuiltIn
        self.isLeadAgent = isLeadAgent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
