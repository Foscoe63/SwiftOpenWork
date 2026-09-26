import Foundation

public struct LLMStreamChunk: Sendable {
    public var deltaText: String
    public var deltaReasoning: String?
    /// Provider-side status — a model load, a cache reset. Shown as a status chip, because it is
    /// infrastructure, not something the model thought.
    public var deltaNotice: String?
    public var isFinished: Bool
    public var finishReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Decode speed the provider measured, when it measures one. Only the in-process engine
    /// does today, and it is the provider where speed decides whether a model is usable.
    public var generationTokensPerSecond: Double?
    public var toolCalls: [ToolCallInfo]
    /// Thinking blocks the provider finished this chunk, verbatim — see `ThinkingBlock`.
    public var thinkingBlocks: [ThinkingBlock]

    public init(
        deltaText: String = "",
        deltaReasoning: String? = nil,
        deltaNotice: String? = nil,
        isFinished: Bool = false,
        finishReason: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        generationTokensPerSecond: Double? = nil,
        toolCalls: [ToolCallInfo] = [],
        thinkingBlocks: [ThinkingBlock] = []
    ) {
        self.deltaText = deltaText
        self.deltaReasoning = deltaReasoning
        self.deltaNotice = deltaNotice
        self.isFinished = isFinished
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.generationTokensPerSecond = generationTokensPerSecond
        self.toolCalls = toolCalls
        self.thinkingBlocks = thinkingBlocks
    }
}

public protocol LLMProviderClient: Sendable {
    func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws
    
    func listModels(provider: ModelProvider) async throws -> [ModelInfo]
    func testConnection(provider: ModelProvider) async throws -> Bool
}

public extension LLMProviderClient {
    func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        try await streamChat(
            provider: provider,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            tools: [],
            onChunk: onChunk
        )
    }
}
