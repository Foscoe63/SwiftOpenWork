import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

public final class OllamaService: LLMProviderClient, Sendable {
    public static let shared = OllamaService()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        let url = URL(string: "\(provider.baseUrl)/api/tags")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode == 200
        }
        return false
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        guard let url = URL(string: "\(provider.baseUrl)/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        
        struct OllamaTagsResponse: Codable {
            struct ModelItem: Codable {
                let name: String
                let size: Int64?
                let details: Details?
                struct Details: Codable {
                    let parameter_size: String?
                    let family: String?
                }
            }
            let models: [ModelItem]
        }

        let parsed = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return parsed.models.map { m in
            ModelInfo(
                id: m.name,
                name: m.name.capitalized,
                providerId: provider.id,
                contextWindow: 32768,
                supportsReasoning: m.name.contains("r1") || m.name.contains("reason"),
                description: "Ollama model: \(m.details?.family ?? "general") (\(m.details?.parameter_size ?? ""))",
                speedTier: "Fast"
            )
        }
    }

    public func pullModel(provider: ModelProvider, modelName: String, onProgress: @Sendable @escaping (Double, String) -> Void) async throws {
        guard let url = URL(string: "\(provider.baseUrl)/api/pull") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": modelName, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "OllamaService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to pull model \(modelName)"])
        }

        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let status = json["status"] as? String ?? "downloading"
                let total = json["total"] as? Double ?? 1.0
                let completed = json["completed"] as? Double ?? 0.0
                let fraction = total > 0 ? (completed / total) : 0.0
                onProgress(fraction, status)
            }
        }
    }

    public func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        guard let url = URL(string: "\(provider.baseUrl)/api/chat") else {
            throw NSError(domain: "OllamaService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var formattedMessages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            formattedMessages.append(["role": "system", "content": systemPrompt])
        }
        let pairing = ToolCallPairing(messages)
        for msg in messages {
            if msg.role == .tool {
                // Prefer native tool role when the request includes tools (Radiant parity).
                if !tools.isEmpty {
                    formattedMessages.append([
                        "role": "tool",
                        "content": msg.content,
                        "tool_call_id": msg.id
                    ])
                } else {
                    formattedMessages.append([
                        "role": "user",
                        "content": "[Tool Result]:\n\(msg.content)\n\nPlease continue your response incorporating the tool result above."
                    ])
                }
            } else {
                var entry: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
                let calls = pairing.answeredCalls(of: msg)
                if !tools.isEmpty, !calls.isEmpty {
                    // Ollama takes arguments as an object, not a JSON string.
                    entry["tool_calls"] = calls.map { call -> [String: Any] in
                        ["function": ["name": call.toolName, "arguments": ToolCallPairing.argumentsObject(call.argumentsJson)]]
                    }
                }
                // Ollama takes images as a sibling array of bare base64 strings, not as
                // content blocks.
                let images = ImageTransport.imageAttachments(in: msg)
                if model.supportsVision, !images.isEmpty {
                    let encoded = ImageTransport.ollamaImages(images)
                    if !encoded.isEmpty { entry["images"] = encoded }
                } else if !images.isEmpty {
                    entry["content"] = msg.content
                        + ImageTransport.blindModelNotice(count: images.count, modelName: model.name)
                }
                formattedMessages.append(entry)
            }
        }

        let loadedSettings = PersistenceManager.shared.loadSettings()
        let repPenalty = loadedSettings.autoAdjustPenaltiesForLocalModels ? max(1.20, loadedSettings.defaultRepeatPenalty) : loadedSettings.defaultRepeatPenalty
        let presPenalty = loadedSettings.autoAdjustPenaltiesForLocalModels ? max(0.30, loadedSettings.defaultPresencePenalty) : loadedSettings.defaultPresencePenalty
        let freqPenalty = loadedSettings.autoAdjustPenaltiesForLocalModels ? max(0.30, loadedSettings.defaultFrequencyPenalty) : loadedSettings.defaultFrequencyPenalty

        var options: [String: Any] = [
            "temperature": temperature,
            "num_predict": maxTokens,
            "repeat_penalty": repPenalty,
            "presence_penalty": presPenalty,
            "frequency_penalty": freqPenalty
        ]
        // See OpenAIService: the Top-P setting used to reach only the in-process MLX path.
        if loadedSettings.defaultTopP > 0, loadedSettings.defaultTopP < 1.0 {
            options["top_p"] = loadedSettings.defaultTopP
        }

        var body: [String: Any] = [
            "model": model.id,
            "messages": formattedMessages,
            "stream": true,
            "options": options
        ]

        if !tools.isEmpty {
            var ollamaTools: [[String: Any]] = []
            for t in tools where t.isEnabled {
                var parametersDict: [String: Any] = ["type": "object", "properties": [String: Any]()]
                if let data = t.parametersJsonSchema.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   !parsed.isEmpty {
                    parametersDict = parsed
                } else {
                    parametersDict = [
                        "type": "object",
                        "properties": [
                            "parameters": ["type": "string", "description": "Parameters for \(t.displayName)"]
                        ]
                    ]
                }
                ollamaTools.append([
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        "parameters": parametersDict
                    ]
                ])
            }
            if !ollamaTools.isEmpty {
                body["tools"] = ollamaTools
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "OllamaService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Ollama returned HTTP error status"])
        }

        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let isDone = json["done"] as? Bool ?? false
                var text = ""
                var reasoning: String? = nil
                var chunkTools: [ToolCallInfo] = []
                
                if let msgDict = json["message"] as? [String: Any] {
                    text = msgDict["content"] as? String ?? ""
                    if let think = msgDict["thinking"] as? String {
                        reasoning = think
                    }
                    if let toolCallsRaw = msgDict["tool_calls"] as? [[String: Any]] {
                        for tc in toolCallsRaw {
                            if let fn = tc["function"] as? [String: Any],
                               let fnName = fn["name"] as? String {
                                let args = fn["arguments"] as? [String: Any] ?? [:]
                                let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
                                let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                                chunkTools.append(ToolCallInfo(
                                    id: UUID().uuidString,
                                    toolName: fnName,
                                    argumentsJson: argsStr,
                                    status: .running
                                ))
                            }
                        }
                    }
                }
                
                let promptTokens = json["prompt_eval_count"] as? Int
                let evalTokens = json["eval_count"] as? Int
                
                onChunk(LLMStreamChunk(
                    deltaText: text,
                    deltaReasoning: reasoning,
                    isFinished: isDone,
                    promptTokens: promptTokens,
                    completionTokens: evalTokens,
                    toolCalls: chunkTools
                ))
            }
        }
    }
}
