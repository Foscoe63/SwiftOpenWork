import Foundation
import SwiftOpenWorkCore

/// Deferred built-in tools. Every enabled tool's full schema rides along with every request, and
/// the specialised ones (worktrees, live preview, screenshots, image generation, PR helpers) are
/// needed in a small share of turns. They are listed by name and one line instead, and the model
/// loads the ones it needs with `tool_describe` — the same shape `MCPToolSearch` gives MCP tools.
/// The everyday set (files, search, shell, git, edits) always stays loaded.
public enum BuiltInToolSearch {

    /// Names that may be deferred. Anything not listed is always sent.
    public static let deferrable: Set<String> = [
        "worktree_create", "worktree_list", "worktree_remove", "worktree_merge",
        "screenshot_window", "accessibility_tree", "run_app", "quit_app",
        "preview_start", "preview_check", "preview_logs", "preview_stop",
        "generate_image", "mlx_vision_describe", "gmail_list", "google_calendar_list",
        "pr_status", "pr_create", "setup_xcode_language_server", "call_hierarchy",
        "document_symbols", "symbol_info", "document_extract", "revert_changes",
    ]

    /// More that a small local model can do without up front. Every schema costs context the model
    /// would rather spend on the task, and a short list is also easier to choose from. Still
    /// loadable with `tool_describe`, and kept loaded when the prompt names what they do.
    public static let compactExtra: Set<String> = [
        "rename_symbol", "find_references", "go_to_definition", "code_diagnostics",
        "file_copy", "file_move", "document_create", "calculator", "get_current_date",
        "memory_store", "memory_recall", "mcp_resources",
    ]

    /// Everything `tool_describe` may load.
    public static var loadable: Set<String> { deferrable.union(compactExtra) }

    /// A local model with a window this size or smaller gets the compact profile. Above it the
    /// schemas are a small share of the window and the extra lookup step is not worth taking.
    public static let compactContextCeiling = 65_536

    public static func usesCompactProfile(providerType: ProviderType, contextWindow: Int) -> Bool {
        providerType == .local && contextWindow <= compactContextCeiling
    }

    /// Below this many deferrable tools the listing costs about what the schemas do.
    public static let minimumToWarrantDeferral = 4

    /// Words too common to say a prompt is about one tool.
    private static let generic: Set<String> = [
        "create", "list", "remove", "merge", "check", "start", "stop", "logs", "status", "describe",
        "symbol", "symbols", "document", "window",
    ]

    /// Extra generic words for the compact profile, whose names include very common ones.
    private static let compactGeneric: Set<String> = [
        "find", "file", "copy", "move", "code", "memory", "store", "recall", "date", "references",
        "resources", "definition", "diagnostics",
    ]

    /// Splits `tools` into those sent in full and those deferred. A tool stays loaded when the
    /// prompt names what it does ("worktree", "screenshot", "preview"), so a request that plainly
    /// needs one does not spend a round trip finding it.
    public static func partition(
        _ tools: [Tool], prompt: String, alreadyLoaded: Set<String> = [], compact: Bool = false
    ) -> (loaded: [Tool], deferred: [Tool]) {
        let pool = compact ? loadable : deferrable
        let candidates = tools.filter { pool.contains($0.name) && !alreadyLoaded.contains($0.name) }
        guard candidates.count >= minimumToWarrantDeferral else { return (tools, []) }
        let lowered = prompt.lowercased()
        let deferredNames = Set(candidates.filter { !promptMentions($0, in: lowered, compact: compact) }.map(\.name))
        guard deferredNames.count >= minimumToWarrantDeferral else { return (tools, []) }
        return (tools.filter { !deferredNames.contains($0.name) }, tools.filter { deferredNames.contains($0.name) })
    }

    static func promptMentions(_ tool: Tool, in loweredPrompt: String, compact: Bool = false) -> Bool {
        tool.name.split(separator: "_").map(String.init)
            .filter { $0.count >= 4 && !generic.contains($0) && !(compact && compactGeneric.contains($0)) }
            .contains { loweredPrompt.contains($0) }
    }

    /// One line per deferred tool, for the system prompt.
    public static func listing(_ deferred: [Tool]) -> String {
        deferred.sorted { $0.name < $1.name }.map { tool in
            let summary = MCPToolSearch.oneLine(tool.description)
            return "- `\(tool.name)`" + (summary.isEmpty ? "" : ": \(summary)")
        }.joined(separator: "\n")
    }

    public static func promptSection(_ deferred: [Tool]) -> String {
        guard !deferred.isEmpty else { return "" }
        return """

        ### More tools (\(deferred.count)) — schemas not loaded
        \(listing(deferred))
        Call `tool_describe` with a tool name or a few keywords to load what you need; the tools it returns are then callable directly. Do not guess parameters for a tool you have not described.
        """
    }
}
