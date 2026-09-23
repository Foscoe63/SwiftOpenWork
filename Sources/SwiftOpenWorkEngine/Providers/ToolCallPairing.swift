import Foundation
import SwiftOpenWorkCore

/// Which tool calls in a transcript have their result right after them.
///
/// OpenAI and Anthropic both require a tool result to answer a call made by the assistant message
/// immediately before it, and every call an assistant message makes to be answered. The agent loop
/// used to send results with no call in front of them, and put the assistant's text *after* its
/// own results; a strict endpoint rejects that, and a lenient local one shows the model its
/// narration out of order, which is how "Let me examine…" came to be repeated seven times in one
/// reply. The loop now records each step as an assistant message carrying its calls, followed by
/// their results. This decides, per message, what can be sent natively:
///
/// - an assistant call is rendered as a native call only if its result follows it;
/// - a result is rendered natively only if it answers such a call, and otherwise as plain text,
///   so a transcript saved before this change still sends.
public struct ToolCallPairing: Sendable {
    /// Ids of calls whose result follows them, in either direction's terms: the call's id and the
    /// result message's id are the same string.
    public let paired: Set<String>

    public init(_ messages: [ChatMessage]) {
        var paired = Set<String>()
        var open = Set<String>()
        for message in messages {
            switch message.role {
            case .assistant:
                open = Set(message.toolCalls.map(\.id))
            case .tool:
                if open.remove(message.id) != nil { paired.insert(message.id) }
            case .user, .system:
                open = []
            }
        }
        self.paired = paired
    }

    /// The calls on `message` to render natively.
    public func answeredCalls(of message: ChatMessage) -> [ToolCallInfo] {
        guard message.role == .assistant else { return [] }
        return message.toolCalls.filter { paired.contains($0.id) }
    }

    /// Whether the result `message` answers a call rendered natively.
    public func isAnswer(_ message: ChatMessage) -> Bool {
        message.role == .tool && paired.contains(message.id)
    }

    /// A call's arguments as an object, for providers that take one rather than a JSON string.
    public static func argumentsObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// A call's arguments as a JSON string that parses, for providers that take a string.
    public static func argumentsString(_ json: String) -> String {
        let object = argumentsObject(json)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
