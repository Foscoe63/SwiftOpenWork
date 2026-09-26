import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

public final class OpenAIService: LLMProviderClient, Sendable {
    public static let shared = OpenAIService()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        let provider = await ProviderCredentials.hydrated(provider)
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models"
        guard let url = URL(string: endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.customHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.timeoutInterval = 8
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode == 200 || http.statusCode == 401 || http.statusCode == 403
        }
        return false
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        let provider = await ProviderCredentials.hydrated(provider)
        let trimmedBase = provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Potential model listing endpoints for OpenAI-compatible, oMLX, vMLX, and local MLX servers:
        var candidateEndpoints: [String] = []
        
        // Derive host root without /v1 or /v2
        var rootBase = trimmedBase
        if rootBase.hasSuffix("/v1") {
            rootBase = String(rootBase.dropLast(3))
        } else if rootBase.hasSuffix("/v2") {
            rootBase = String(rootBase.dropLast(3))
        }
        
        // 1. Standard OpenAI v1 endpoints
        candidateEndpoints.append("\(trimmedBase)/models")
        candidateEndpoints.append("\(rootBase)/v1/models")
        candidateEndpoints.append("\(rootBase)/models")
        
        // 2. oMLX, vMLX, and MLX-LM local server endpoints
        candidateEndpoints.append("\(rootBase)/api/models")
        candidateEndpoints.append("\(rootBase)/api/tags")
        candidateEndpoints.append("\(rootBase)/api/v1/models")
        candidateEndpoints.append("\(rootBase)/v1/models/list")
        candidateEndpoints.append("\(rootBase)/models/list")
        candidateEndpoints.append("\(rootBase)/local_models")
        candidateEndpoints.append("\(rootBase)/api/local_models")
        candidateEndpoints.append("\(rootBase)/api/downloaded_models")
        candidateEndpoints.append("\(rootBase)/downloaded_models")
        candidateEndpoints.append("\(rootBase)/api/installed_models")
        candidateEndpoints.append("\(rootBase)/installed_models")
        candidateEndpoints.append("\(rootBase)/api/available_models")
        candidateEndpoints.append("\(rootBase)/available_models")

        var lastError: Error? = nil

        for endpoint in candidateEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if !provider.apiKey.isEmpty {
                request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
            }
            for (k, v) in provider.customHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
            request.timeoutInterval = 4

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }

                if let models = parseModelsResponse(data: data, provider: provider), !models.isEmpty {
                    return models
                }
            } catch {
                lastError = error
            }
        }

        // If dynamic endpoints didn't return models, check if server is reachable and throw or return empty
        // Don't silently return hardcoded default dummy models when the user explicitly queries their server!
        if let lastError = lastError {
            throw lastError
        }
        return []
    }

    private func parseModelsResponse(data: Data, provider: ModelProvider) -> [ModelInfo]? {
        // Attempt 1: Standard OpenAI format { "data": [ { "id": "...", ... } ] }
        struct OpenAIModelsResponse: Codable {
            struct Item: Codable {
                let id: String
                let name: String?
                let owned_by: String?
            }
            let data: [Item]?
        }
        if let parsed = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data),
           let list = parsed.data, !list.isEmpty {
            return list.map { m in
                makeModelInfo(id: m.id, name: m.name, ownedBy: m.owned_by, providerId: provider.id)
            }
        }

        // Attempt 2: Direct array at root: [ { "id": "..." } ] or [ "mlx-community/...", "..." ]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var results: [ModelInfo] = []
            for item in array {
                if let id = item["id"] as? String ?? item["name"] as? String ?? item["model"] as? String ?? item["model_name"] as? String ?? item["repo_id"] as? String ?? item["path"] as? String {
                    let name = item["name"] as? String ?? item["display_name"] as? String
                    results.append(makeModelInfo(id: id, name: name, ownedBy: item["owned_by"] as? String, providerId: provider.id))
                }
            }
            if !results.isEmpty { return results }
        }

        if let strArray = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return strArray.map { makeModelInfo(id: $0, name: nil, ownedBy: nil, providerId: provider.id) }
        }

        // Attempt 3: JSON dict with common keys ("models", "data", "result", "items", "loaded_models", "downloaded_models", "local_models", "installed_models")
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidates = ["models", "data", "result", "items", "loaded_models", "available_models", "downloaded_models", "local_models", "installed_models", "tags"]
            for key in candidates {
                if let list = dict[key] as? [[String: Any]] {
                    var results: [ModelInfo] = []
                    for item in list {
                        if let id = item["id"] as? String ?? item["name"] as? String ?? item["model"] as? String ?? item["model_name"] as? String ?? item["repo_id"] as? String ?? item["path"] as? String {
                            let name = item["name"] as? String ?? item["display_name"] as? String
                            results.append(makeModelInfo(id: id, name: name, ownedBy: item["owned_by"] as? String, providerId: provider.id))
                        }
                    }
                    if !results.isEmpty { return results }
                } else if let list = dict[key] as? [String] {
                    return list.map { makeModelInfo(id: $0, name: nil, ownedBy: nil, providerId: provider.id) }
                }
            }

            // Attempt 4: Dictionary of models as key-values: { "models": { "model_id_1": {...}, "model_id_2": {...} } } or root dictionary of model objects
            for key in candidates {
                if let map = dict[key] as? [String: Any] {
                    var results: [ModelInfo] = []
                    for (k, v) in map {
                        if let vDict = v as? [String: Any] {
                            let id = vDict["id"] as? String ?? vDict["model"] as? String ?? k
                            let name = vDict["name"] as? String ?? vDict["display_name"] as? String
                            results.append(makeModelInfo(id: id, name: name, ownedBy: vDict["owned_by"] as? String, providerId: provider.id))
                        } else {
                            results.append(makeModelInfo(id: k, name: nil, ownedBy: nil, providerId: provider.id))
                        }
                    }
                    if !results.isEmpty { return results }
                }
            }

            // Attempt 5: Single loaded model response (e.g. { "model": "...", "status": "loaded" })
            if let singleName = dict["model"] as? String ?? dict["loaded_model"] as? String ?? dict["active_model"] as? String ?? dict["model_path"] as? String ?? dict["repo_id"] as? String {
                return [makeModelInfo(id: singleName, name: nil, ownedBy: "active", providerId: provider.id)]
            }
        }

        return nil
    }

    private func makeModelInfo(id: String, name: String?, ownedBy: String?, providerId: String) -> ModelInfo {
        let isReasoning = id.contains("r1") || id.contains("o1") || id.contains("o3") || id.contains("reason")
        let displayName = name ?? id.components(separatedBy: "/").last ?? id
        return KnownModels.applying(to: ModelInfo(
            id: id,
            name: displayName,
            providerId: providerId,
            contextWindow: 128000,
            supportsVision: id.contains("4o") || id.contains("vision") || id.contains("vl") || id.contains("claude") || id.contains("pixtral"),
            supportsReasoning: isReasoning,
            supportsStreaming: true,
            supportsTools: id.contains("coder") || id.contains("gpt") || id.contains("claude") || id.contains("qwen"),
            description: "Provider model (\(ownedBy ?? "standard"))",
            speedTier: isReasoning ? "Powerful" : "Fast"
        ))
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
        let provider = await ProviderCredentials.hydrated(provider)
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "OpenAIService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.customHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        var formattedMessages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            formattedMessages.append(["role": "system", "content": systemPrompt])
        }
        let isLocalEndpoint = provider.baseUrl.contains("mlx") || provider.baseUrl.contains("127.0.0.1") || provider.baseUrl.contains("localhost")
        // Images. Every provider used to serialize `content` as a bare String, so an attached
        // screenshot never reached the model and the reply discussed a picture it had not seen.
        var blindImageCount = 0
        let pairing = ToolCallPairing(messages)
        for msg in messages {
            let images = ImageTransport.imageAttachments(in: msg)
            let canSee = model.supportsVision && !images.isEmpty
            if !images.isEmpty && !model.supportsVision { blindImageCount += images.count }

            if msg.role == .tool && !pairing.isAnswer(msg) {
                // A result with no call in front of it: `tool` would be rejected, so it goes as
                // text. Only transcripts from before the loop recorded its calls look like this.
                formattedMessages.append(["role": "user", "content": "[Tool output]\n" + msg.content])
            } else if msg.role == .tool {
                // Radiant / OpenAI-compat: native tool role + tool_call_id.
                // (Legacy user-role wrapping caused local models to ignore observations.)
                formattedMessages.append([
                    "role": "tool",
                    "content": msg.content,
                    "tool_call_id": msg.id
                ])
                // A `tool` message may not carry image blocks in the OpenAI schema, so the
                // pixels follow as their own user turn rather than being dropped.
                if canSee {
                    formattedMessages.append([
                        "role": "user",
                        "content": ImageTransport.openAIContent(
                            text: "Screenshot produced by the previous tool call:",
                            images: images
                        )
                    ])
                }
            } else if canSee {
                formattedMessages.append([
                    "role": msg.role.rawValue,
                    "content": ImageTransport.openAIContent(text: msg.content, images: images)
                ])
            } else {
                var entry: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
                let calls = pairing.answeredCalls(of: msg)
                if !calls.isEmpty {
                    entry["tool_calls"] = calls.map { call -> [String: Any] in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.toolName,
                                "arguments": ToolCallPairing.argumentsString(call.argumentsJson),
                            ],
                        ]
                    }
                }
                formattedMessages.append(entry)
            }
        }

        // Say so rather than discarding silently — the old behaviour let the model discuss a
        // screenshot it had never received.
        if blindImageCount > 0, let last = formattedMessages.indices.last {
            let text = formattedMessages[last]["content"] as? String ?? ""
            formattedMessages[last]["content"] = text
                + ImageTransport.blindModelNotice(count: blindImageCount, modelName: model.name)
        }

        let loadedSettings = PersistenceManager.shared.loadSettings()
        let presencePenalty = loadedSettings.autoAdjustPenaltiesForLocalModels && isLocalEndpoint ? max(0.35, loadedSettings.defaultPresencePenalty) : loadedSettings.defaultPresencePenalty
        let frequencyPenalty = loadedSettings.autoAdjustPenaltiesForLocalModels && isLocalEndpoint ? max(0.35, loadedSettings.defaultFrequencyPenalty) : loadedSettings.defaultFrequencyPenalty

        var body: [String: Any] = [
            "model": model.id,
            "messages": formattedMessages,
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "presence_penalty": presencePenalty,
            "frequency_penalty": frequencyPenalty
        ]

        // Top-P reached only the in-process MLX path; the slider on the Sampling card did nothing
        // for any OpenAI-compatible endpoint. Sent only when the user has moved it off 1.0, since
        // 1.0 is a no-op and OpenAI advises against steering with temperature and top_p together.
        if loadedSettings.defaultTopP > 0, loadedSettings.defaultTopP < 1.0 {
            body["top_p"] = loadedSettings.defaultTopP
        }

        if model.supportsReasoning && reasoningEffort != .off {
            body["reasoning_effort"] = reasoningEffort.rawValue
        }

        // Add native structured tool schemas whenever tools are provided (including local
        // OpenAI-compatible endpoints — Radiant parity).
        if !tools.isEmpty {
            var toolsArray: [[String: Any]] = []
            for t in tools where t.isEnabled {
                var parametersDict: [String: Any] = ["type": "object", "properties": [String: Any]()]
                if let data = t.parametersJsonSchema.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   !parsed.isEmpty {
                    parametersDict = parsed
                } else {
                    // Provide automatic typed schema based on tool type
                    switch t.name {
                    case "file_read":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Relative or absolute path to the file to read"]
                            ],
                            "required": ["path"]
                        ]
                    case "file_write":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Relative or absolute path to the file to write"],
                                "content": ["type": "string", "description": "Text or code content to write to the file"]
                            ],
                            "required": ["path", "content"]
                        ]
                    case "file_list":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Directory path to list files for"]
                            ]
                        ]
                    case "terminal_command":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "command": ["type": "string", "description": "Bash/zsh shell command to execute"],
                                "cwd": ["type": "string", "description": "Working directory path for execution"]
                            ],
                            "required": ["command"]
                        ]
                    case "web_search":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "Search engine query string"]
                            ],
                            "required": ["query"]
                        ]
                    case "calculator":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "expression": ["type": "string", "description": "Mathematical formula to evaluate"]
                            ],
                            "required": ["expression"]
                        ]
                    case "document_extract", "extract_document", "read_pdf_or_image":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "File path to PDF document or image for OCR"]
                            ],
                            "required": ["path"]
                        ]
                    case "workspace_semantic_search":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "Semantic query or concept to search across workspace code"],
                                "top_k": ["type": "integer", "description": "Number of top matches to return"]
                            ],
                            "required": ["query"]
                        ]
                    case "agent_spawn":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "target_agent_id": ["type": "string", "description": "Which agent to delegate to - its id or name, from the configured agents"],
                                "task_title": ["type": "string", "description": "The objective, stated so it can be worked on without further questions"],
                                "task_description": ["type": "string", "description": "Context the sub-agent needs: files, constraints, what done looks like"]
                            ],
                            "required": ["target_agent_id", "task_title"]
                        ]
                    case "agent_message":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "to_agent_id": ["type": "string", "description": "Target agent ID or 'broadcast'"],
                                "to_agent_name": ["type": "string", "description": "Target agent name"],
                                "content": ["type": "string", "description": "Message content or query to deliver to the other agent"],
                                "message_type": ["type": "string", "description": "Type: task_delegation, task_response, consultation, or broadcast"]
                            ],
                            "required": ["content"]
                        ]
                    case "mcp_call":
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "server": ["type": "string", "description": "Name or ID of the MCP server (e.g. 'macuse', 'filesystem', 'fetch')"],
                                "tool": ["type": "string", "description": "Tool or action name to run on the MCP server (e.g. 'get_calendar_events', 'get_reminders')"],
                                "arguments": ["type": "object", "description": "Arguments/parameters for the tool"]
                            ],
                            "required": ["server", "tool"]
                        ]
                    case _ where t.category == .mcp || t.name.contains("_call"):
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "description": "Action or tool to execute on the MCP server (e.g. 'get_calendar_events', 'query')"],
                                "parameters": ["type": "object", "description": "Key-value parameters for the MCP action"]
                            ]
                        ]
                    default:
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "parameters": ["type": "string", "description": "Tool parameters in string or JSON form"]
                            ]
                        ]
                    }
                }

                toolsArray.append([
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        "parameters": parametersDict
                    ]
                ])
            }
            if !toolsArray.isEmpty {
                body["tools"] = toolsArray
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw NSError(domain: "OpenAIService", code: status, userInfo: [NSLocalizedDescriptionKey: "Provider returned HTTP status \(status)"])
        }

        // Track accumulating tool calls across streaming deltas
        var toolCalls = ToolCallStreamAssembler()
        var finalizedToolCalls = false

        AppLog.verbose(.stream, "POST \(url.absoluteString) model=\(model.id) tools=\(tools.filter(\.isEnabled).count)")

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // What "Verbose Logging" promises by name: the raw SSE payloads.
            AppLog.verbose(.stream, "SSE \(AppLog.truncated(payload))")
            if payload == "[DONE]" {
                // Finalize any pending streamed tool calls, in the order they were made.
                finalizedToolCalls = true
                onChunk(LLMStreamChunk(isFinished: true, toolCalls: toolCalls.assembled()))
                break
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            
            // A usage-only chunk (`"choices": []`) is how servers report token counts when they
            // report them separately; it was skipped, so the context meter and cost never saw it.
            if let choices = json["choices"] as? [[String: Any]], choices.isEmpty,
               let usage = json["usage"] as? [String: Any] {
                onChunk(LLMStreamChunk(
                    promptTokens: usage["prompt_tokens"] as? Int,
                    completionTokens: usage["completion_tokens"] as? Int
                ))
                continue
            }

            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                let finishReason = first["finish_reason"] as? String
                var text = ""
                var reasoning: String? = nil
                var deltaToolCalls: [ToolCallInfo] = []
                
                if let delta = first["delta"] as? [String: Any] {
                    text = delta["content"] as? String ?? ""
                    if let reason = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String {
                        reasoning = reason
                    }

                    // Native tool_calls delta parsing
                    if let fragments = delta["tool_calls"] as? [[String: Any]] {
                        deltaToolCalls = toolCalls.ingest(fragments)
                    }
                }
                
                let usage = json["usage"] as? [String: Any]
                let promptTok = usage?["prompt_tokens"] as? Int
                let compTok = usage?["completion_tokens"] as? Int

                onChunk(LLMStreamChunk(
                    deltaText: text,
                    deltaReasoning: reasoning,
                    isFinished: finishReason != nil && finishReason != "",
                    finishReason: finishReason,
                    promptTokens: promptTok,
                    completionTokens: compTok,
                    toolCalls: deltaToolCalls
                ))
            }
        }

        // Servers that end the stream without `[DONE]` (finish_reason, then close) left their
        // calls unannounced.
        if !finalizedToolCalls, !toolCalls.isEmpty {
            onChunk(LLMStreamChunk(isFinished: true, toolCalls: toolCalls.assembled()))
        }
    }
}
