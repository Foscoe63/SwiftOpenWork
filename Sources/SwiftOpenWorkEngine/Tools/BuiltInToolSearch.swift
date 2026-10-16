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

    /// Below this many deferrable tools the listing costs about what the schemas do.
    public static let minimumToWarrantDeferral = 4

    /// Words too common to say a prompt is about one tool.
    private static let generic: Set<String> = [
        "create", "list", "remove", "merge", "check", "start", "stop", "logs", "status", "describe",
        "symbol", "symbols", "document", "window",
    ]

    /// Splits `tools` into those sent in full and those deferred. A tool stays loaded when the
    /// prompt names what it does ("worktree", "screenshot", "preview"), so a request that plainly
    /// needs one does not spend a round trip finding it.
    public static func partition(
        _ tools: [Tool], prompt: String, alreadyLoaded: Set<String> = []
    ) -> (loaded: [Tool], deferred: [Tool]) {
        let candidates = tools.filter { deferrable.contains($0.name) && !alreadyLoaded.contains($0.name) }
        guard candidates.count >= minimumToWarrantDeferral else { return (tools, []) }
        let lowered = prompt.lowercased()
        let deferredNames = Set(candidates.filter { !promptMentions($0, in: lowered) }.map(\.name))
        guard deferredNames.count >= minimumToWarrantDeferral else { return (tools, []) }
        return (tools.filter { !deferredNames.contains($0.name) }, tools.filter { deferredNames.contains($0.name) })
    }

    static func promptMentions(_ tool: Tool, in loweredPrompt: String) -> Bool {
        tool.name.split(separator: "_").map(String.init)
            .filter { $0.count >= 4 && !generic.contains($0) }
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
