import Foundation
import SwiftOpenWorkCore

/// Deferred MCP tools: with many servers connected, sending every tool's full schema in every
/// request costs tens of thousands of tokens, slows the first token, and makes tool choice worse.
/// Past `threshold` tools the model is shown names and one-line descriptions only, and loads the
/// schemas it needs with `mcp_describe`.
public enum MCPToolSearch {

    /// Live MCP tools beyond which schemas are deferred.
    public static let threshold = 12
    public static let defaultLimit = 6
    public static let maxLimit = 12
    /// Entries listed in the prompt before the rest are left to `mcp_describe`.
    public static let maxListed = 120

    public static func shouldDefer(toolCount: Int) -> Bool { toolCount > threshold }

    /// Tools whose name, description or server contains every word of `query`, best match first.
    /// An exact tool name wins outright.
    public static func match(query: String, in tools: [Tool], limit: Int = defaultLimit) -> [Tool] {
        let cap = min(max(1, limit), maxLimit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        if let exact = tools.first(where: { $0.name.lowercased() == trimmed }) { return [exact] }
        let words = trimmed.split(whereSeparator: { " ,;".contains($0) }).map(String.init)
        let scored: [(tool: Tool, score: Int)] = tools.compactMap { tool in
            let name = tool.name.lowercased()
            let leaf = (MCPNamespacedTool.parse(tool.name)?.toolName ?? tool.name).lowercased()
            let haystack = name + " " + tool.description.lowercased()
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            let score = words.reduce(0) { $0 + (leaf.contains($1) ? 3 : name.contains($1) ? 2 : 1) }
            return (tool, score)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.tool.name < $1.tool.name }
            .prefix(cap).map(\.tool)
    }

    /// What the model reads back: each tool's name, description and parameter schema.
    public static func describe(_ tools: [Tool]) -> String {
        tools.map { tool in
            "### \(tool.name)\n\(tool.description)\nParameters: \(tool.parametersJsonSchema)"
        }.joined(separator: "\n\n")
    }

    /// The first sentence of a description, short enough for a one-line listing.
    public static func oneLine(_ description: String, limit: Int = 90) -> String {
        let flat = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let sentence = flat.range(of: ". ").map { String(flat[..<$0.lowerBound]) } ?? flat
        return sentence.count <= limit ? sentence : String(sentence.prefix(limit - 1)) + "…"
    }

    /// Per-server listing of names with descriptions, capped at `maxListed` entries overall.
    public static func listing(tools: [Tool], serverName: (String) -> String) -> String {
        let byServer = Dictionary(grouping: tools) { MCPNamespacedTool.parse($0.name)?.serverId ?? "mcp" }
        var remaining = maxListed
        var lines: [String] = []
        for serverId in byServer.keys.sorted() {
            let entries = (byServer[serverId] ?? []).sorted { $0.name < $1.name }
            let shown = entries.prefix(max(0, remaining))
            remaining -= shown.count
            var block = "- **\(serverName(serverId))** (`\(serverId)`, \(entries.count) tools)"
            for tool in shown {
                let leaf = MCPNamespacedTool.parse(tool.name)?.toolName ?? tool.name
                let summary = oneLine(tool.description)
                block += "\n  - `\(leaf)`" + (summary.isEmpty ? "" : ": \(summary)")
            }
            if entries.count > shown.count { block += "\n  - … \(entries.count - shown.count) more; search with `mcp_describe`" }
            lines.append(block)
        }
        return lines.joined(separator: "\n")
    }
}
