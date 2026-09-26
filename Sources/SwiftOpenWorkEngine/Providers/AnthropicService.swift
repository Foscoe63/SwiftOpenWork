import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

public final class AnthropicService: LLMProviderClient, Sendable {
    public static let shared = AnthropicService()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        let provider = await ProviderCredentials.hydrated(provider)
        guard !provider.apiKey.isEmpty else { return false }
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models"
        guard let url = URL(string: endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 8
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode == 200 || http.statusCode == 400
        }
        return false
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        let provider = await ProviderCredentials.hydrated(provider)
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models"
        if let url = URL(string: endpoint), !provider.apiKey.isEmpty {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 8
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                struct AnthropicModelsResponse: Codable {
                    struct Item: Codable {
                        let id: String
                        let display_name: String?
                    }
                    let data: [Item]?
                }
                if let parsed = try? JSONDecoder().decode(AnthropicModelsResponse.self, from: data),
                   let data = parsed.data, !data.isEmpty {
                    return data.map { m in
                        // Every Claude 3.7+ model can think; only the older 3.0/3.5 line cannot.
                        let isLegacy = m.id.contains("claude-3-opus") || m.id.contains("3-5-") || m.id.contains("claude-3-haiku")
                        let isReasoning = !isLegacy
                        let info = ModelInfo(
                            id: m.id,
                            name: m.display_name ?? m.id,
                            providerId: provider.id,
                            contextWindow: 200000,
                            supportsVision: true,
                            supportsReasoning: isReasoning,
                            supportsStreaming: true,
                            supportsTools: true,
                            description: "Anthropic Claude Model",
                            isDefault: m.id.contains("sonnet-5"),
                            speedTier: m.id.contains("haiku") ? "Fast" : "Powerful",
                            costPer1kPrompt: m.id.contains("haiku") ? 0.0008 : 0.003,
                            costPer1kCompletion: m.id.contains("haiku") ? 0.004 : 0.015
                        )
                        // Context and price from the shared table when the model is one we know;
                        // the heuristics above only stand in for models it doesn't list.
                        return KnownModels.applying(to: info)
                    }
                }
            }
        }

        // Offline fallback when `/models` cannot be reached.
        return [
            ("claude-sonnet-5", true), ("claude-opus-5-5", false), ("claude-fable-5-1", false),
            ("claude-haiku-4-5-20251001", false),
        ].map { id, isDefault in
            KnownModels.applying(to: ModelInfo(
                id: id,
                name: KnownModels.spec(for: id)?.displayName ?? id,
                providerId: provider.id,
                supportsVision: true,
                supportsReasoning: true,
                isDefault: isDefault,
                speedTier: id.contains("haiku") ? "Fast" : "Powerful"
            ))
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
        let provider = await ProviderCredentials.hydrated(provider)
        let endpoint = "\(provider.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/messages"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "AnthropicService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // What this model accepts differs by generation — see `AnthropicRequestPolicy`. The old
        // shape (`thinking: enabled` + `temperature`) is a 400 on the current Claude 5 models.
        let shape = AnthropicRequestPolicy.shape(
            modelId: model.id,
            supportsReasoning: model.supportsReasoning,
            effort: reasoningEffort,
            temperature: temperature,
            topP: PersistenceManager.shared.loadSettings().defaultTopP,
            maxTokens: maxTokens
        )
        // Thinking blocks go back only when this request thinks — see `AnthropicRequestPolicy`.
        let replayThinking = AnthropicRequestPolicy.carriesThinking(shape, modelId: model.id)

        var formattedMessages: [[String: Any]] = []
        var blindImageCount = 0
        let pairing = ToolCallPairing(messages)
        for msg in messages {
            let images = ImageTransport.imageAttachments(in: msg)
            let canSee = model.supportsVision && !images.isEmpty
            if !images.isEmpty && !model.supportsVision { blindImageCount += images.count }

            if msg.role == .tool && pairing.isAnswer(msg) {
                // Unlike OpenAI, a `tool_result` block may itself contain images, so a screenshot
                // stays attached to the call that produced it.
                var resultContent: Any = msg.content
                if canSee {
                    resultContent = ImageTransport.anthropicContent(text: msg.content, images: images)
                }
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": msg.id,
                    "content": resultContent
                ]
                // Every result for one assistant turn belongs in the single user turn after it.
                if let last = formattedMessages.indices.last,
                   formattedMessages[last]["role"] as? String == "user",
                   var blocks = formattedMessages[last]["content"] as? [[String: Any]],
                   blocks.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                    blocks.append(block)
                    formattedMessages[last]["content"] = blocks
                } else {
                    formattedMessages.append(["role": "user", "content": [block]])
                }
            } else if msg.role == .tool {
                // No `tool_use` in front of it, which the API rejects as a `tool_result`.
                formattedMessages.append(["role": "user", "content": "[Tool output]\n" + msg.content])
            } else {
                let role = msg.role == .assistant ? "assistant" : "user"
                let calls = pairing.answeredCalls(of: msg)
                if !calls.isEmpty {
                    var blocks: [[String: Any]] = []
                    // The turn's thinking blocks, verbatim and first. Without them the model
                    // restarts its reasoning after every tool result.
                    if replayThinking {
                        blocks += AnthropicRequestPolicy.replayBlocks(for: msg.thinkingBlocks, modelId: model.id)
                    }
                    if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(["type": "text", "text": msg.content])
                    }
                    for call in calls {
                        blocks.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.toolName,
                            "input": ToolCallPairing.argumentsObject(call.argumentsJson),
                        ])
                    }
                    formattedMessages.append(["role": role, "content": blocks])
                    continue
                }
                formattedMessages.append([
                    "role": role,
                    "content": canSee
                        ? ImageTransport.anthropicContent(text: msg.content, images: images)
                        : msg.content
                ])
            }
        }
        if blindImageCount > 0, let last = formattedMessages.indices.last,
           let text = formattedMessages[last]["content"] as? String {
            formattedMessages[last]["content"] = text
                + ImageTransport.blindModelNotice(count: blindImageCount, modelName: model.name)
        }

        var body: [String: Any] = [
            "model": model.id,
            "messages": formattedMessages,
            "stream": true,
            "max_tokens": maxTokens,
            "system": systemPrompt
        ]

        if let thinking = shape.thinking { body["thinking"] = thinking }
        if let outputConfig = shape.outputConfig { body["output_config"] = outputConfig }
        if let temperature = shape.temperature { body["temperature"] = temperature }
        if let topP = shape.topP { body["top_p"] = topP }

        // Add native tools in Anthropic schema { name: "...", description: "...", input_schema: {...} }
        if !tools.isEmpty {
            var anthropicTools: [[String: Any]] = []
            for t in tools where t.isEnabled {
                var parametersDict: [String: Any] = ["type": "object", "properties": [String: Any]()]
                if let data = t.parametersJsonSchema.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   !parsed.isEmpty {
                    parametersDict = parsed
                } else {
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
                                "query": ["type": "string", "description": "Semantic query to search across workspace files"],
                                "top_k": ["type": "integer", "description": "Top matches to return"]
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
                                "server": ["type": "string", "description": "Name or ID of the MCP server (e.g. 'macuse', 'filesystem')"],
                                "tool": ["type": "string", "description": "Tool or action name to run on the MCP server"],
                                "arguments": ["type": "object", "description": "Arguments for the tool"]
                            ],
                            "required": ["server", "tool"]
                        ]
                    case _ where t.category == .mcp || t.name.contains("_call"):
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "description": "Action or tool to execute on the MCP server"],
                                "parameters": ["type": "object", "description": "Key-value parameters for the MCP action"]
                            ]
                        ]
                    default:
                        parametersDict = [
                            "type": "object",
                            "properties": [
                                "parameters": ["type": "string", "description": "Parameters for this tool"]
                            ]
                        ]
                    }
                }

                anthropicTools.append([
                    "name": t.name,
                    "description": t.description,
                    "input_schema": parametersDict
                ])
            }
            if !anthropicTools.isEmpty {
                body["tools"] = anthropicTools
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw NSError(domain: "AnthropicService", code: status, userInfo: [NSLocalizedDescriptionKey: "Anthropic returned HTTP status \(status)"])
        }

        var currentToolUseId = ""
        var currentToolName = ""
        var currentToolArgs = ""
        var thinkingCapture = ThinkingStreamCapture()

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let eventType = json["type"] as? String

            // Thinking blocks are captured verbatim, from the same events, so they can go back
            // with the tool results. The reasoning shown to the user is handled below, as before.
            if let block = thinkingCapture.handle(json, modelId: model.id) {
                onChunk(LLMStreamChunk(thinkingBlocks: [block]))
            }

            if eventType == "error" {
                // An overload or server fault mid-stream arrives as an event, not an HTTP status,
                // and was skipped — the reply just stopped, with nothing saying why.
                let detail = (json["error"] as? [String: Any])?["message"] as? String ?? "the stream reported an error"
                let kind = (json["error"] as? [String: Any])?["type"] as? String ?? "error"
                throw NSError(domain: "AnthropicService", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "Anthropic stream error (\(kind)): \(detail)"
                ])
            }

            // Token counts, so the context meter and session cost have something to show. Input
            // arrives in `message_start`; output in `message_delta`. Cached input counts as input:
            // it occupies the window whether or not it was billed at the discounted rate.
            if eventType == "message_start",
               let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                onChunk(LLMStreamChunk(promptTokens: input))
            } else if eventType == "message_delta",
                      let usage = json["usage"] as? [String: Any],
                      let output = usage["output_tokens"] as? Int {
                onChunk(LLMStreamChunk(completionTokens: output))
            }

            if eventType == "content_block_start" {
                if let contentBlock = json["content_block"] as? [String: Any],
                   contentBlock["type"] as? String == "tool_use" {
                    currentToolUseId = contentBlock["id"] as? String ?? UUID().uuidString
                    currentToolName = contentBlock["name"] as? String ?? ""
                    currentToolArgs = ""
                }
            } else if eventType == "content_block_delta" {
                if let delta = json["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String
                    if deltaType == "text_delta" {
                        let text = delta["text"] as? String ?? ""
                        onChunk(LLMStreamChunk(deltaText: text))
                    } else if deltaType == "thinking_delta" {
                        let reasoning = delta["thinking"] as? String ?? ""
                        onChunk(LLMStreamChunk(deltaReasoning: reasoning))
                    } else if deltaType == "input_json_delta" {
                        let partialJson = delta["partial_json"] as? String ?? ""
                        currentToolArgs += partialJson
                    }
                }
            } else if eventType == "content_block_stop" {
                if !currentToolName.isEmpty {
                    let toolCall = ToolCallInfo(
                        id: currentToolUseId,
                        toolName: currentToolName,
                        argumentsJson: currentToolArgs.isEmpty ? "{}" : currentToolArgs,
                        status: .running
                    )
                    onChunk(LLMStreamChunk(toolCalls: [toolCall]))
                    currentToolUseId = ""
                    currentToolName = ""
                    currentToolArgs = ""
                }
            } else if eventType == "message_stop" {
                onChunk(LLMStreamChunk(isFinished: true))
            }
        }
    }
}
