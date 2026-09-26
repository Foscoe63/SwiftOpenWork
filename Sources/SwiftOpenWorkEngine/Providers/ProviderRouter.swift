import Foundation
import SwiftOpenWorkCore

public final class ProviderRouter: Sendable {
    public static let shared = ProviderRouter()

    private init() {}

    public func client(for provider: ModelProvider) -> LLMProviderClient {
        switch provider.kind {
        case .omlx, .vmlx:
            return LocalInferenceRegistry.engine
        case .ollama:
            return OllamaService.shared
        case .anthropic:
            return AnthropicService.shared
        case .openai, .groq, .openrouter, .deepseek, .lmstudio, .llamacpp, .splash, .mistral, .gemini, .custom:
            return OpenAIService.shared
        }
    }

    public func stream(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool] = [],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        var activeProvider = provider

        // Built-in Apple Silicon / MLX: in-process engine, then optional local OpenAI-compatible
        // servers. Never silently replace failures with MockLLMService — that made every prompt
        // look identical ("offline fallback mode") regardless of the selected model.
        if provider.kind == .omlx || provider.kind == .vmlx {
            do {
                try await LocalInferenceRegistry.engine.streamChat(
                    provider: activeProvider,
                    model: model,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    reasoningEffort: reasoningEffort,
                    tools: tools,
                    onChunk: onChunk
                )
                return
            } catch {
                let detail = error.localizedDescription
                onChunk(LLMStreamChunk(
                    deltaText: """
                    \n\n⚠️ **Built-in MLX unavailable**

                    \(detail)

                    **What to do**
                    - Open **Local Models** and finish downloading a complete MLX model, or
                    - Switch the model picker to **Ollama**, **LM Studio**, or a **cloud** provider.
                    """,
                    isFinished: true
                ))
                throw error
            }
        }

        // Ollama uses its own HTTP API (`/api/chat`) and must keep its configured base URL.
        // Do NOT rewrite it through LocalMLXEngine (that appends `/v1` and breaks Ollama).
        if activeProvider.kind == .ollama {
            let selectedClient = OllamaService.shared
            do {
                try await selectedClient.streamChat(
                    provider: activeProvider,
                    model: model,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    reasoningEffort: reasoningEffort,
                    tools: tools,
                    onChunk: onChunk
                )
                return
            } catch {
                onChunk(LLMStreamChunk(
                    deltaText: "\n\n⚠️ **Ollama Error:** \(error.localizedDescription)\n\nIs Ollama running? Default URL: `\(activeProvider.baseUrl)`.",
                    isFinished: true
                ))
                throw error
            }
        }

        // Other local OpenAI-compatible backends. LM Studio, llama.cpp and Splash each have their
        // own configured endpoint, so they go straight to it: the launcher below probes port 8000
        // first and would rewrite the URL to whichever server answers, sending LM Studio traffic
        // to Splash (or the reverse) when both are running.
        let usesConfiguredEndpoint = [ProviderKind.lmstudio, .llamacpp, .splash].contains(activeProvider.kind)
        if activeProvider.type == .local && !usesConfiguredEndpoint {
            let res = await LocalInferenceRegistry.serverLauncher?.ensureServerRunning(modelId: model.id, settings: nil)
                ?? (success: false, message: "No local server launcher is registered in this build.", activePort: 0)
            if !res.success {
                let msg = res.message.isEmpty ? "Local backend failed to start." : res.message
                onChunk(LLMStreamChunk(
                    deltaText: "\n\n⚠️ **Local Model Error:** \(msg)",
                    isFinished: true
                ))
                throw NSError(
                    domain: "ProviderRouter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
            }
            // Only rewrite base URL for OpenAI-compatible local servers — never for Ollama.
            if res.activePort != 11434 {
                activeProvider.baseUrl = "http://127.0.0.1:\(res.activePort)/v1"
            }

            let selectedClient = client(for: activeProvider)
            do {
                try await selectedClient.streamChat(
                    provider: activeProvider,
                    model: model,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    reasoningEffort: reasoningEffort,
                    tools: tools,
                    onChunk: onChunk
                )
                return
            } catch {
                onChunk(LLMStreamChunk(
                    deltaText: "\n\n⚠️ **Local Model Error:** \(error.localizedDescription)",
                    isFinished: true
                ))
                throw error
            }
        }

        // Remote / Cloud Providers (OpenAI, Anthropic, Groq, etc.)
        let selectedClient = client(for: activeProvider)
        do {
            try await selectedClient.streamChat(
                provider: activeProvider,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                tools: tools,
                onChunk: onChunk
            )
        } catch {
            onChunk(LLMStreamChunk(
                deltaText: "\n\n⚠️ **Provider Error (\(activeProvider.name)):**\n`\(error.localizedDescription)`\n\nPlease check your API key and network connection in Settings > Providers.",
                isFinished: true
            ))
            throw error
        }
    }
}
