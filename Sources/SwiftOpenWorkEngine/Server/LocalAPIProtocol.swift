import Foundation
import SwiftOpenWorkCore

/// The wire formats of the local model server: OpenAI's Chat Completions and Anthropic's Messages.
///
/// Pure translation, no sockets. A request becomes the app's own `ChatMessage`s and `Tool`s, goes
/// through `ProviderRouter` like any chat turn, and the stream of `LLMStreamChunk`s becomes either
/// format's response. That is what lets Claude Code, Codex, OpenCode or an editor use the model that
/// is already loaded in this app, with its KV cache and its scheduling, instead of loading a
/// second copy in another server.
public enum LocalAPIProtocol {

    public enum Flavor: Sendable { case openAI, anthropic }

    public struct Request: Sendable {
        public var flavor: Flavor
        public var model: String?
        public var system: String
        public var messages: [ChatMessage]
        public var tools: [Tool]
        public var temperature: Double
        public var maxTokens: Int
        public var stream: Bool
    }

    public struct Failure: Error, Sendable {
        public var status: Int
        public var message: String
    }

    public static let defaultMaxTokens = 4096

    // MARK: - Requests

    public static func parse(_ data: Data, flavor: Flavor) throws -> Request {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(status: 400, message: "The request body is not a JSON object.")
        }
        guard let raw = object["messages"] as? [Any], !raw.isEmpty else {
            throw Failure(status: 400, message: "`messages` is required and must not be empty.")
        }
        var system = ""
        var messages: [ChatMessage] = []
        if flavor == .anthropic { system = text(of: object["system"]) }

        for case let entry as [String: Any] in raw {
            let role = (entry["role"] as? String) ?? "user"
            switch (flavor, role) {
            case (.openAI, "system"), (.openAI, "developer"):
                let line = text(of: entry["content"])
                system += (system.isEmpty ? "" : "\n\n") + line
            case (.openAI, "tool"):
                messages.append(ChatMessage(
                    id: (entry["tool_call_id"] as? String) ?? UUID().uuidString, role: .tool, content: text(of: entry["content"])
                ))
            case (.openAI, "assistant"):
                var calls: [ToolCallInfo] = []
                for case let call as [String: Any] in (entry["tool_calls"] as? [Any]) ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    guard let name = function["name"] as? String else { continue }
                    let arguments: String
                    if let string = function["arguments"] as? String { arguments = string.isEmpty ? "{}" : string }
                    else if let object = function["arguments"], let data = try? JSONSerialization.data(withJSONObject: object) { arguments = String(decoding: data, as: UTF8.self) }
                    else { arguments = "{}" }
                    calls.append(ToolCallInfo(id: (call["id"] as? String) ?? UUID().uuidString, toolName: name, argumentsJson: arguments, status: .completed))
                }
                messages.append(ChatMessage(role: .assistant, content: text(of: entry["content"]), toolCalls: calls))
            case (.openAI, _):
                messages.append(ChatMessage(role: .user, content: text(of: entry["content"])))
            case (.anthropic, "assistant"):
                var calls: [ToolCallInfo] = []
                var body = ""
                for block in blocks(entry["content"]) {
                    switch block["type"] as? String {
                    case "text": body += (block["text"] as? String) ?? ""
                    case "tool_use":
                        guard let name = block["name"] as? String else { continue }
                        let arguments = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [String: Any]())).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        calls.append(ToolCallInfo(id: (block["id"] as? String) ?? UUID().uuidString, toolName: name, argumentsJson: arguments, status: .completed))
                    default: break
                    }
                }
                messages.append(ChatMessage(role: .assistant, content: body, toolCalls: calls))
            case (.anthropic, _):
                // A user turn can mix tool results with new text; results come first, in order.
                var body = ""
                for block in blocks(entry["content"]) {
                    switch block["type"] as? String {
                    case "tool_result":
                        messages.append(ChatMessage(
                            id: (block["tool_use_id"] as? String) ?? UUID().uuidString, role: .tool, content: text(of: block["content"])
                        ))
                    case "text": body += (block["text"] as? String) ?? ""
                    default: break
                    }
                }
                if !body.isEmpty { messages.append(ChatMessage(role: .user, content: body)) }
            }
        }

        var tools: [Tool] = []
        for case let entry as [String: Any] in (object["tools"] as? [Any]) ?? [] {
            let function = (entry["function"] as? [String: Any]) ?? entry
            guard let name = function["name"] as? String, !name.isEmpty else { continue }
            let schemaObject = function["parameters"] ?? function["input_schema"] ?? ["type": "object", "properties": [String: Any]()]
            let schema = (try? JSONSerialization.data(withJSONObject: schemaObject)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            tools.append(Tool(
                id: name, name: name, displayName: name, description: (function["description"] as? String) ?? "",
                category: .system, parametersJsonSchema: schema
            ))
        }

        return Request(
            flavor: flavor,
            model: object["model"] as? String,
            system: system,
            messages: messages,
            tools: tools,
            temperature: (object["temperature"] as? Double) ?? 0.7,
            maxTokens: intValue(object["max_tokens"]) ?? intValue(object["max_completion_tokens"]) ?? defaultMaxTokens,
            stream: (object["stream"] as? Bool) ?? false
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    private static func blocks(_ content: Any?) -> [[String: Any]] {
        if let string = content as? String { return [["type": "text", "text": string]] }
        return (content as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A message's text from a string or a list of parts; other parts (images) are noted, not dropped silently.
    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        var pieces: [String] = []
        for case let part as [String: Any] in (content as? [Any]) ?? [] {
            switch part["type"] as? String {
            case "text", "input_text": pieces.append((part["text"] as? String) ?? "")
            case "tool_result": pieces.append(text(of: part["content"]))
            case "image_url", "image", "input_image": pieces.append("[image omitted: this endpoint is text-only]")
            default: break
            }
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - OpenAI responses

    public struct Completion: Sendable {
        public var text = ""
        public var reasoning = ""
        public var toolCalls: [ToolCallInfo] = []
        public var finishReason: String?
        public var promptTokens = 0
        public var completionTokens = 0

        public var openAIFinish: String {
            if !toolCalls.isEmpty { return "tool_calls" }
            switch finishReason {
            case "length", "max_tokens": return "length"
            default: return "stop"
            }
        }
        public var anthropicStop: String {
            if !toolCalls.isEmpty { return "tool_use" }
            switch finishReason {
            case "length", "max_tokens": return "max_tokens"
            default: return "end_turn"
            }
        }
    }

    public static func openAIResponse(id: String, model: String, _ completion: Completion, created: Int = Int(Date().timeIntervalSince1970)) -> Data {
        var message: [String: Any] = ["role": "assistant", "content": completion.text]
        if !completion.reasoning.isEmpty { message["reasoning_content"] = completion.reasoning }
        if !completion.toolCalls.isEmpty {
            message["tool_calls"] = completion.toolCalls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.toolName, "arguments": call.argumentsJson]] as [String: Any]
            }
            if completion.text.isEmpty { message["content"] = NSNull() }
        }
        return json([
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [["index": 0, "message": message, "finish_reason": completion.openAIFinish]],
            "usage": ["prompt_tokens": completion.promptTokens, "completion_tokens": completion.completionTokens,
                      "total_tokens": completion.promptTokens + completion.completionTokens],
        ])
    }

    /// One `data:` frame of a streamed Chat Completion.
    public static func openAIFrame(id: String, model: String, delta: [String: Any], finish: String? = nil, usage: Completion? = nil, created: Int = Int(Date().timeIntervalSince1970)) -> String {
        var chunk: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]],
        ]
        if let usage {
            chunk["usage"] = ["prompt_tokens": usage.promptTokens, "completion_tokens": usage.completionTokens,
                              "total_tokens": usage.promptTokens + usage.completionTokens]
        }
        return "data: " + String(decoding: json(chunk), as: UTF8.self) + "\n\n"
    }

    public static func openAIToolCallDelta(_ call: ToolCallInfo, index: Int) -> [String: Any] {
        ["tool_calls": [["index": index, "id": call.id, "type": "function",
                         "function": ["name": call.toolName, "arguments": call.argumentsJson]] as [String: Any]]]
    }

    public static let openAIDone = "data: [DONE]\n\n"

    // MARK: - Anthropic responses

    public static func anthropicResponse(id: String, model: String, _ completion: Completion) -> Data {
        var content: [[String: Any]] = []
        if !completion.text.isEmpty || completion.toolCalls.isEmpty { content.append(["type": "text", "text": completion.text]) }
        for call in completion.toolCalls {
            let input = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJson.utf8))) ?? [String: Any]()
            content.append(["type": "tool_use", "id": call.id, "name": call.toolName, "input": input])
        }
        return json([
            "id": id, "type": "message", "role": "assistant", "model": model, "content": content,
            "stop_reason": completion.anthropicStop, "stop_sequence": NSNull(),
            "usage": ["input_tokens": completion.promptTokens, "output_tokens": completion.completionTokens],
        ])
    }

    /// `event:`/`data:` pair of a streamed Messages response.
    public static func anthropicEvent(_ type: String, _ payload: [String: Any]) -> String {
        var body = payload
        body["type"] = type
        return "event: \(type)\ndata: " + String(decoding: json(body), as: UTF8.self) + "\n\n"
    }

    // MARK: - Misc

    public static func modelsList(_ models: [(id: String, owner: String)], flavor: Flavor) -> Data {
        switch flavor {
        case .openAI:
            return json(["object": "list", "data": models.map { ["id": $0.id, "object": "model", "created": 0, "owned_by": $0.owner] as [String: Any] }])
        case .anthropic:
            return json(["data": models.map { ["id": $0.id, "type": "model", "display_name": $0.id, "created_at": "1970-01-01T00:00:00Z"] as [String: Any] },
                         "has_more": false, "first_id": models.first?.id as Any? ?? NSNull(), "last_id": models.last?.id as Any? ?? NSNull()])
        }
    }

    public static func errorBody(_ failure: Failure, flavor: Flavor) -> Data {
        switch flavor {
        case .openAI:
            return json(["error": ["message": failure.message, "type": failure.status >= 500 ? "server_error" : "invalid_request_error", "code": NSNull()]])
        case .anthropic:
            return json(["type": "error", "error": ["type": failure.status == 401 ? "authentication_error" : (failure.status >= 500 ? "api_error" : "invalid_request_error"), "message": failure.message]])
        }
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
