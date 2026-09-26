import Foundation

public struct ModelInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var providerId: String
    public var contextWindow: Int
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var supportsStreaming: Bool
    public var supportsTools: Bool
    public var description: String
    public var isDefault: Bool
    public var speedTier: String // Fast, Balanced, Powerful
    public var costPer1kPrompt: Double
    public var costPer1kCompletion: Double

    public init(
        id: String,
        name: String,
        providerId: String = "",
        contextWindow: Int = 128000,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false,
        supportsStreaming: Bool = true,
        supportsTools: Bool = true,
        description: String = "",
        isDefault: Bool = false,
        speedTier: String = "Balanced",
        costPer1kPrompt: Double = 0.0,
        costPer1kCompletion: Double = 0.0
    ) {
        self.id = id
        self.name = name
        self.providerId = providerId
        self.contextWindow = contextWindow
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.supportsStreaming = supportsStreaming
        self.supportsTools = supportsTools
        self.description = description
        self.isDefault = isDefault
        self.speedTier = speedTier
        self.costPer1kPrompt = costPer1kPrompt
        self.costPer1kCompletion = costPer1kCompletion
    }
}

public enum ProviderType: String, Codable, CaseIterable, Sendable {
    case local = "local"
    case cloud = "cloud"
}

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama = "ollama"
    case omlx = "omlx"
    case vmlx = "vmlx"
    case lmstudio = "lmstudio"
    case llamacpp = "llamacpp"
    case splash = "splash"
    case openai = "openai"
    case anthropic = "anthropic"
    case openrouter = "openrouter"
    case groq = "groq"
    case mistral = "mistral"
    case gemini = "gemini"
    case deepseek = "deepseek"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .omlx: return "oMLX (Apple Silicon Local)"
        case .vmlx: return "vMLX (Apple Silicon Vision/LLM)"
        case .lmstudio: return "LM Studio (Local)"
        case .llamacpp: return "Llama.cpp (Local)"
        case .splash: return "Splash (Apple Silicon Local)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .mistral: return "Mistral AI"
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    public var defaultBaseUrl: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .omlx: return "http://127.0.0.1:8000/v1"
        case .vmlx: return "http://127.0.0.1:8080/v1"
        case .lmstudio: return "http://127.0.0.1:1234/v1"
        case .llamacpp: return "http://127.0.0.1:8080/v1"
        case .splash: return "http://127.0.0.1:8000/v1"
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .custom: return "https://api.example.com/v1"
        }
    }

    public var type: ProviderType {
        switch self {
        case .ollama, .omlx, .vmlx, .lmstudio, .llamacpp, .splash:
            return .local
        default:
            return .cloud
        }
    }

    public var icon: String {
        switch self {
        case .ollama: return "desktopcomputer"
        case .omlx: return "cpu.fill"
        case .vmlx: return "eye.circle.fill"
        case .lmstudio: return "cpu"
        case .llamacpp: return "terminal"
        case .splash: return "bolt.horizontal.fill"
        case .openai: return "sparkles"
        case .anthropic: return "brain"
        case .openrouter: return "network"
        case .groq: return "bolt.fill"
        case .mistral: return "wind"
        case .gemini: return "diamond.fill"
        case .deepseek: return "waveform.path.ecg"
        case .custom: return "server.rack"
        }
    }
}

public struct ModelProvider: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: ProviderType
    public var kind: ProviderKind
    public var baseUrl: String
    public var apiKey: String
    public var isEnabled: Bool
    public var isDefault: Bool
    public var models: [ModelInfo]
    public var customHeaders: [String: String]
    public var organizationId: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        type: ProviderType,
        kind: ProviderKind,
        baseUrl: String = "",
        apiKey: String = "",
        isEnabled: Bool = true,
        isDefault: Bool = false,
        models: [ModelInfo] = [],
        customHeaders: [String: String] = [:],
        organizationId: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.kind = kind
        self.baseUrl = baseUrl.isEmpty ? kind.defaultBaseUrl : baseUrl
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.models = models
        self.customHeaders = customHeaders
        self.organizationId = organizationId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
