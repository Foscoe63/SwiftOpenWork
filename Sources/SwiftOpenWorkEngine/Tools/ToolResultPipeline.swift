import Foundation

/// What a tool result looks like by the time the model reads it.
///
/// Replaces calling `ToolBounds.boundResult` directly. That cut every oversized result to its head
/// and tail and threw the middle away. This keeps the middle: the full text goes into
/// `ToolOutputStore`, the model sees a shortened form that says where the rest is, and
/// `recall_output` fetches any part of it.
///
/// Lossy shortening is limited to tools whose output is a report about something (commands,
/// builds, tests, web and MCP results). A file the model read is never rewritten, because it will
/// copy text from it into an edit and a summary has no exact text to copy.
public enum ToolResultPipeline {

    /// Results shorter than this are never touched.
    public static let compressAboveChars = 8_000
    /// What a compressed result aims for (about 1,250 tokens).
    public static let compressedTargetChars = 5_000
    /// A compressed form that saves less than this share is not worth the indirection.
    static let minimumSavingFraction = 0.15

    public struct Outcome: Sendable {
        public let text: String
        /// Shown in the transcript. Set only when information was lost without being kept: the
        /// recall footer already tells the model about the rest.
        public let notice: String?
        public let savedCharacters: Int
        public let storedAs: String?
    }

    /// Tools that report on something, so a shorter report is a fair substitute for a longer one.
    static func allowsLossyCompression(toolName: String) -> Bool {
        if MCPNamespacedTool.isNamespaced(toolName) { return true }
        switch ToolCallRepair.canonicalName(toolName) {
        case "terminal_command", "send_input", "build_project", "run_tests", "fetch_url", "web_search",
             "mcp_call", "call_mcp_tool", "mcp_resources", "git_log", "pr_status", "preview_logs",
             "code_diagnostics":
            return true
        default:
            return false
        }
    }

    public static func process(_ text: String, toolName: String, sessionId: String?) -> Outcome {
        // Reading output back must not itself be shortened and re-stored.
        if ToolCallRepair.canonicalName(toolName) == "recall_output" {
            let bounded = ToolBounds.boundResult(text)
            return Outcome(text: bounded.text, notice: bounded.notice, savedCharacters: bounded.truncatedChars, storedAs: nil)
        }

        let length = text.count
        if allowsLossyCompression(toolName: toolName), length > compressAboveChars {
            let kind = OutputCompressor.classify(text, toolName: toolName)
            let compressed = OutputCompressor.compress(text, kind: kind, targetChars: compressedTargetChars)
            if Double(compressed.count) <= Double(length) * (1 - minimumSavingFraction) {
                let id = ToolOutputStore.shared.store(text: text, toolName: toolName, sessionId: sessionId)
                let result = compressed + footer(id: id, from: length, to: compressed.count, kind: kind)
                let saved = max(0, length - result.count)
                ContextSavings.shared.record(sessionId: sessionId, savedCharacters: saved)
                return Outcome(text: result, notice: nil, savedCharacters: saved, storedAs: id)
            }
        }

        if length > ToolBounds.maxResultChars {
            let bounded = ToolBounds.boundResult(text)
            let id = ToolOutputStore.shared.store(text: text, toolName: toolName, sessionId: sessionId)
            let result = bounded.text + footer(id: id, from: length, to: bounded.text.count, kind: nil)
            let saved = max(0, length - result.count)
            ContextSavings.shared.record(sessionId: sessionId, savedCharacters: saved)
            return Outcome(text: result, notice: bounded.notice, savedCharacters: saved, storedAs: id)
        }

        return Outcome(text: text, notice: nil, savedCharacters: 0, storedAs: nil)
    }

    static func footer(id: String, from original: Int, to shortened: Int, kind: OutputCompressor.Kind?) -> String {
        let how = kind.map { " (\($0.rawValue) summary)" } ?? ""
        return "\n\n[Output shortened\(how): \(original) → \(shortened) chars. The full text is saved as `\(id)`; "
            + "call recall_output with that id and a `query` (words to find) or `start`/`lines` to read the exact text.]"
    }
}
