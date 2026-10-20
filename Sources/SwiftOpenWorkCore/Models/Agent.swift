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

/// A coding agent that runs as its own program and speaks the Agent Client Protocol over stdio:
/// Claude Code, Codex, Gemini CLI, OpenCode, Goose and others. An agent with this set is run by
/// launching that program, instead of by the app's own loop.
public struct ExternalAgentConfig: Codable, Hashable, Sendable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    /// Model alias or id to switch the agent to after it starts ("sonnet", "opus", "haiku", or a
    /// full id). nil means the app's default for that agent; "default" leaves the agent's own choice.
    public var model: String?
    /// Start the agent with a small context: only the project's settings (not the user's global
    /// MCP servers, skills and plugins) and no notebook tool. nil means on for Claude Code.
    public var leanContext: Bool?

    public init(command: String, args: [String] = [], env: [String: String] = [:], model: String? = nil, leanContext: Bool? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.model = model
        self.leanContext = leanContext
    }

    /// Claude Code, through the Zed adapter or its own CLI.
    public var isClaudeCode: Bool {
        args.contains(where: { $0.contains("claude-code-acp") }) || command.hasSuffix("claude")
    }

    /// The model to switch to, or nil to leave the agent's own default. Claude Code defaults to
    /// Sonnet: its own default is Opus, which uses a plan's allowance several times faster.
    public var effectiveModel: String? {
        let chosen = model?.trimmingCharacters(in: .whitespaces).lowercased()
        if chosen == "default" { return nil }
        if let chosen, !chosen.isEmpty { return chosen }
        return isClaudeCode ? "sonnet" : nil
    }

    public var effectiveLeanContext: Bool { leanContext ?? isClaudeCode }

    /// The command line as the person would type it, for display.
    public var displayLine: String {
        ([command] + args).joined(separator: " ")
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
    /// Set for an agent that is another program, reached over ACP. nil for the app's own agents,
    /// and for every agent saved before this existed.
    public var externalAgent: ExternalAgentConfig?

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
        updatedAt: Date = Date(),
        externalAgent: ExternalAgentConfig? = nil
    ) {
        self.externalAgent = externalAgent
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
