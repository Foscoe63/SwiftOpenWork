import Foundation
import SwiftOpenWorkCore

/// Serves requests from the app's own providers: the models you have set up, through the same
/// router a chat turn uses, so the in-process engine's cache and queue apply.
public struct LiveLocalAPIBackend: LocalAPIBackend {
    public init() {}

    /// Providers whose models run on this Mac or on a server the user runs themselves.
    static func isLocal(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .omlx, .vmlx, .ollama, .lmstudio, .llamacpp, .splash: return true
        default: return false
        }
    }

    @MainActor
    private func candidates() -> [(provider: ModelProvider, model: ModelInfo)] {
        guard let host = EngineHosting.host else { return [] }
        let exposeCloud = host.settings.localAPIExposeCloudModels
        return host.providers
            .filter { $0.isEnabled && (exposeCloud || Self.isLocal($0.kind)) }
            .flatMap { provider in provider.models.map { (provider, $0) } }
    }

    public func models() async -> [(id: String, owner: String)] {
        await MainActor.run { candidates().map { ($0.model.id, $0.provider.name) } }
    }

    public func generate(_ request: LocalAPIProtocol.Request, onChunk: @Sendable @escaping (LLMStreamChunk) -> Void) async throws {
        let chosen: (provider: ModelProvider, model: ModelInfo)? = await MainActor.run {
            guard let host = EngineHosting.host else { return nil }
            let all = candidates()
            if let wanted = request.model, let match = all.first(where: { $0.model.id == wanted || $0.model.name == wanted }) { return match }
            // A client that sends a name it made up (Claude Code sends Claude model ids) gets the
            // model selected in the app, when that one is allowed.
            let current = (host.currentProvider, host.currentModel)
            if all.contains(where: { $0.provider.id == current.0.id && $0.model.id == current.1.id }) { return current }
            return all.first
        }
        guard let chosen else {
            throw LocalAPIProtocol.Failure(status: 404, message: "No model is available. Load one in SwiftOpenWork, or enable cloud models for the local API in Settings.")
        }
        try await ProviderRouter.shared.stream(
            provider: chosen.provider, model: chosen.model,
            systemPrompt: request.system, messages: request.messages,
            temperature: request.temperature, maxTokens: request.maxTokens,
            reasoningEffort: .off, tools: request.tools, onChunk: onChunk
        )
    }
}
