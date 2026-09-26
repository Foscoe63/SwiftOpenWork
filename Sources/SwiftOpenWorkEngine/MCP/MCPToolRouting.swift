import Foundation
import SwiftOpenWorkCore

/// Outcome of resolving which MCP server should service a call.
public enum MCPServerResolution: Equatable, Sendable {
    case resolved(MCPServerConfig)
    /// Model-facing text explaining what went wrong *and* what to call instead.
    case failed(String)
}

/// Server/tool identity resolution for MCP calls.
///
/// Every lookup here refuses ambiguity rather than silently taking the first match: a call that
/// could belong to two enabled servers resolves to `nil`, which becomes an error telling the model
/// to pass `server` explicitly. Guessing produces calls that run against the wrong server and
/// report success, which is worse than a clear failure.
public enum MCPToolRouting: Sendable {
    // MARK: - Naming

    public static func slug(_ server: MCPServerConfig) -> String {
        let raw = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = raw.lowercased().replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? server.id : slug
    }

    /// Strip `[id=…]` decorations and surrounding whitespace that models attach to names.
    public static func stripDecor(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = trimmed.firstIndex(of: "[") {
            trimmed = String(trimmed[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func normalized(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Server resolution

    /// The one enabled server matching `raw`, or nil when zero or more than one match.
    public static func canonicalServer(_ raw: String, in servers: [MCPServerConfig]) -> MCPServerConfig? {
        let needle = normalized(stripDecor(raw))
        guard !needle.isEmpty else { return nil }

        var candidate = needle
        // Peel decorations models add (`user-github`, `mcp:github`, `mcp_github`) one layer per pass.
        for _ in 0..<6 {
            if let hit = uniqueMatch(candidate, in: servers) { return hit }
            if candidate.hasPrefix("user_") {
                candidate = String(candidate.dropFirst(5))
                continue
            }
            if candidate.hasPrefix("mcp:") {
                candidate = String(candidate.dropFirst(4))
                continue
            }
            if candidate.hasPrefix("mcp_") {
                candidate = String(candidate.dropFirst(4))
                continue
            }
            break
        }
        return nil
    }

    private static func uniqueMatch(_ needle: String, in servers: [MCPServerConfig]) -> MCPServerConfig? {
        let hits = servers.filter { server in
            normalized(server.id) == needle
                || normalized(server.name) == needle
                || normalized(slug(server)) == needle
        }
        return hits.count == 1 ? hits[0] : nil
    }

    // MARK: - Tool resolution

    /// Match `raw` against a server's advertised tool names. Ambiguous matches return nil.
    ///
    /// `allowSingleFallback` accepts the only advertised tool when the name does not match —
    /// safe when the caller has already pinned the server.
    public static func canonicalTool(
        _ raw: String,
        known: [String],
        allowSingleFallback: Bool = false
    ) -> String? {
        let trimmed = stripDecor(raw)
        guard !trimmed.isEmpty else { return nil }
        if known.contains(trimmed) { return trimmed }

        let caseInsensitive = known.filter { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        if caseInsensitive.count == 1 { return caseInsensitive[0] }

        let hyphen = trimmed.replacingOccurrences(of: "_", with: "-")
        let under = trimmed.replacingOccurrences(of: "-", with: "_")
        let swapped = known.filter { $0 == hyphen || $0 == under }
        if swapped.count == 1 { return swapped[0] }

        if allowSingleFallback, known.count == 1 { return known[0] }
        return nil
    }

    /// Which enabled server owns `raw`. Requires exactly one owner.
    ///
    /// `advertised` maps server id → the tool names that server reported from `tools/list`.
    public static func serverOwning(
        tool raw: String,
        servers: [MCPServerConfig],
        advertised: [String: [String]]
    ) -> (server: MCPServerConfig, tool: String)? {
        let trimmed = stripDecor(raw)
        guard !trimmed.isEmpty else { return nil }

        // 1. Fully namespaced `mcp__serverId__tool` — the server half is authoritative.
        if let parsed = MCPNamespacedTool.parse(trimmed),
           let server = canonicalServer(parsed.serverId, in: servers) {
            let known = advertised[server.id] ?? []
            if let tool = canonicalTool(parsed.toolName, known: known, allowSingleFallback: true) {
                return (server, tool)
            }
            // Server is pinned and we have no catalog yet — trust the leaf name.
            if known.isEmpty { return (server, parsed.toolName) }
        }

        // 2. Exact advertised name, unique across enabled servers.
        var exact: [(MCPServerConfig, String)] = []
        for server in servers {
            if let tool = canonicalTool(trimmed, known: advertised[server.id] ?? []) {
                exact.append((server, tool))
            }
        }
        if exact.count == 1 { return exact[0] }

        // 3. `<slug>__tool` / `<slug>_tool`, unique across enabled servers.
        var prefixed: [(MCPServerConfig, String)] = []
        for server in servers {
            let serverSlug = slug(server)
            let underscored = serverSlug.replacingOccurrences(of: "-", with: "_")
            let known = advertised[server.id] ?? []
            let prefixes = Set(["\(serverSlug)__", "\(underscored)__", "\(serverSlug)_", "\(underscored)_"])
            for prefix in prefixes where trimmed.lowercased().hasPrefix(prefix) {
                let rest = String(trimmed.dropFirst(prefix.count))
                guard !rest.isEmpty else { continue }
                if let tool = canonicalTool(rest, known: known) {
                    prefixed.append((server, tool))
                } else if known.isEmpty {
                    prefixed.append((server, rest))
                }
            }
        }
        let unique = uniqued(prefixed)
        return unique.count == 1 ? unique[0] : nil
    }

    private static func uniqued(_ hits: [(MCPServerConfig, String)]) -> [(MCPServerConfig, String)] {
        var seen = Set<String>()
        var out: [(MCPServerConfig, String)] = []
        for hit in hits where seen.insert("\(hit.0.id)/\(hit.1)").inserted {
            out.append(hit)
        }
        return out
    }

    // MARK: - Full resolution

    /// Resolve the server for a call. Never defaults to "the first enabled server" when the
    /// request is ambiguous — it returns instructions instead.
    public static func resolveServer(
        requested: String,
        toolName: String = "",
        enabled: [MCPServerConfig],
        advertised: [String: [String]] = [:]
    ) -> MCPServerResolution {
        guard !enabled.isEmpty else {
            return .failed(noServersMessage())
        }

        let needle = stripDecor(requested)
        if !needle.isEmpty {
            if let match = canonicalServer(needle, in: enabled) {
                return .resolved(match)
            }
            return .failed(unknownServerMessage(requested: needle, enabled: enabled))
        }

        if let owned = serverOwning(tool: toolName, servers: enabled, advertised: advertised) {
            return .resolved(owned.server)
        }

        if enabled.count == 1 {
            return .resolved(enabled[0])
        }

        return .failed(needServerMessage(toolName: toolName, enabled: enabled))
    }

    // MARK: - Model-facing messages
    //
    // Every one of these names the enabled servers and the exact next call. A tool result that
    // only says "failed" makes the model retry the same broken call; one that says what to call
    // instead makes it recover on the next step.

    public static func noServersMessage() -> String {
        """
        No MCP servers are enabled. Nothing was executed. \
        Add and enable a server in Settings → Tools & MCP, or use a built-in tool instead.
        """
    }

    public static func unknownServerMessage(requested: String, enabled: [MCPServerConfig]) -> String {
        let names = enabled.map(\.name).joined(separator: ", ")
        let example = enabled.first?.name ?? "the server name"
        return """
        Unknown or disabled MCP server '\(requested)'. Nothing was executed. \
        Enabled servers: \(names). Pass server by name (e.g. server=\(example)) or call the \
        namespaced tool directly as mcp__<serverId>__<tool>.
        """
    }

    public static func needServerMessage(toolName: String, enabled: [MCPServerConfig]) -> String {
        let names = enabled.map(\.name).joined(separator: ", ")
        let example = enabled.first?.name ?? "the server name"
        let subject = toolName.isEmpty ? "This call" : "'\(toolName)'"
        return """
        \(subject) did not identify an MCP server, and more than one is enabled, so nothing was \
        executed. Enabled servers: \(names). Retry with server=\(example) (or the correct one), \
        or call the namespaced tool directly as mcp__<serverId>__<tool>. Do not guess a server.
        """
    }

    public static func unknownToolMessage(
        tool: String,
        server: MCPServerConfig,
        advertised: [String]
    ) -> String {
        let known = advertised.sorted().prefix(25).joined(separator: ", ")
        let more = advertised.count > 25 ? " (+\(advertised.count - 25) more)" : ""
        if advertised.isEmpty {
            return """
            MCP server '\(server.name)' has not reported a tool list yet, so '\(tool)' could not \
            be verified and nothing was executed. Retry once the server is connected, or check \
            Settings → Tools & MCP for its status.
            """
        }
        return """
        Tool '\(tool)' is not advertised by MCP server '\(server.name)'. Nothing was executed. \
        Available tools: \(known)\(more). Use one of those exact names — do not invent tool names.
        """
    }
}
