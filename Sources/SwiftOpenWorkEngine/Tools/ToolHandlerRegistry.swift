import Foundation
import SwiftOpenWorkCore

/// Everything a built-in tool handler needs about the call it is running.
///
/// `toolName` and `dict` are the repaired forms (`ToolCallRepair`): the canonical name or the
/// alias the model used, and the arguments with alternative keys already normalised.
struct ToolCall {
    let toolName: String
    let dict: [String: Any]
    let argumentsJson: String
    let workspace: Workspace
    let currentAgent: Agent
    let settings: AppSettings
    let startTime: Double
    let callId: String?
}

typealias ToolHandler = @Sendable (ToolExecutionEngine, sending ToolCall) async -> ToolExecutionResult

/// One built-in tool: every name the model may call it by, and the code that runs it.
struct ToolRegistration: Sendable {
    let names: [String]
    let run: ToolHandler

    init(_ names: [String], run: @escaping ToolHandler) {
        self.names = names
        self.run = run
    }
}

/// The built-in tools, by name. Adding a tool is one handler method and one `ToolRegistration`
/// in the family file it belongs to (`Tools/Handlers/`); nothing here changes.
enum ToolHandlerRegistry {
    static let registrations: [ToolRegistration] =
        ToolExecutionEngine.fileToolHandlers
        + ToolExecutionEngine.gitToolHandlers
        + ToolExecutionEngine.codeToolHandlers
        + ToolExecutionEngine.shellToolHandlers
        + ToolExecutionEngine.webToolHandlers
        + ToolExecutionEngine.sessionToolHandlers
        + ToolExecutionEngine.perceptionToolHandlers
        + ToolExecutionEngine.agentToolHandlers
        + ToolExecutionEngine.mcpToolHandlers

    static let handlers: [String: ToolHandler] = {
        var table: [String: ToolHandler] = [:]
        for registration in registrations {
            for name in registration.names {
                precondition(table[name] == nil, "two tool handlers are registered for \(name)")
                table[name] = registration.run
            }
        }
        return table
    }()

    /// Every name a built-in handler answers to, aliases included.
    static var names: Set<String> { Set(handlers.keys) }
}
