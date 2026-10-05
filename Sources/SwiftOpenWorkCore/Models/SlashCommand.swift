import Foundation

/// A command the user defined: `/standup` sends a saved prompt.
public struct CustomSlashCommand: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    /// Always lower case with a leading slash, e.g. `/standup`.
    public var command: String
    public var description: String
    /// What is sent. `$ARGUMENTS` is replaced by whatever follows the command; with no
    /// placeholder, the arguments are appended after a blank line.
    public var prompt: String

    public init(id: String = UUID().uuidString, command: String, description: String = "", prompt: String) {
        self.id = id
        self.command = command
        self.description = description
        self.prompt = prompt
    }
}

/// The commands the app handles itself, and the rules for adding to them.
public enum SlashCommands {

    public struct BuiltIn: Sendable, Equatable {
        public let command: String
        public let description: String
    }

    /// Handled in `AppState.handleSlashCommand`. A custom command may not take one of these names.
    public static let builtIn: [BuiltIn] = [
        BuiltIn(command: "/compact", description: "Shrink what the model is sent; your chat stays as is"),
        BuiltIn(command: "/clear", description: "Clear messages in this session"),
        BuiltIn(command: "/plan", description: "Toggle plan mode (read-only until exit_plan_mode)"),
        BuiltIn(command: "/agent", description: "Switch the active agent, or open the Agents hub"),
        BuiltIn(command: "/model", description: "Switch the active model, or open Providers"),
        BuiltIn(command: "/settings", description: "Open App Settings"),
        BuiltIn(command: "/tools", description: "Inspect MCP & built-in tools"),
        BuiltIn(command: "/memory", description: "Search or view long-term memory"),
        BuiltIn(command: "/help", description: "Show the command reference"),
    ]

    public static let argumentsPlaceholder = "$ARGUMENTS"

    /// `Standup` and `/Standup ` both become `/standup`.
    public static func normalized(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !name.hasPrefix("/") { name = "/" + name }
        return name
    }

    /// Why `command` cannot be saved, or nil. `editing` is the command being changed, which
    /// may keep its own name.
    public static func problem(
        command raw: String,
        prompt: String,
        existing: [CustomSlashCommand],
        editing: String? = nil
    ) -> String? {
        let command = normalized(raw)
        let body = command.dropFirst()
        if body.isEmpty { return "Give the command a name." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        if body.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use letters, digits, - and _ only, with no spaces."
        }
        if builtIn.contains(where: { $0.command == command }) {
            return "\(command) is a built-in command."
        }
        if existing.contains(where: { $0.command == command && $0.id != editing }) {
            return "\(command) already exists."
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write the prompt this command sends."
        }
        return nil
    }

    /// The text to send for `input` when it names a custom command, otherwise nil.
    public static func expand(_ input: String, custom: [CustomSlashCommand]) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = trimmed.prefix { !$0.isWhitespace }.lowercased()
        guard let match = custom.first(where: { $0.command == name }) else { return nil }
        let arguments = String(trimmed.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if match.prompt.contains(argumentsPlaceholder) {
            return match.prompt.replacingOccurrences(of: argumentsPlaceholder, with: arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return arguments.isEmpty ? match.prompt : match.prompt + "\n\n" + arguments
    }
}
