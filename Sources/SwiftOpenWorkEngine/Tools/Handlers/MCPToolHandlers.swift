import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// The generic MCP entry points: resources, describe and call.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let mcpToolHandlers: [ToolRegistration] = [
        ToolRegistration(["mcp_resources"]) { await $0.mcpResourcesTool($1) },
        ToolRegistration(["mcp_describe"]) { await $0.mcpDescribeTool($1) },
        ToolRegistration(["mcp_call", "call_mcp_tool"]) { await $0.mcpCallTool($1) },
    ]

    func mcpResourcesTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let settings = call.settings
        let startTime = call.startTime
        let enabled = settings.mcpServers.filter(\.isEnabled)
        let requested = (dict["server"] as? String ?? "").lowercased()
        guard let server = enabled.first(where: { $0.id.lowercased() == requested || $0.name.lowercased() == requested }) else {
            return Self.mcpFailure(
                "Unknown MCP server '\(requested)'. Enabled: \(enabled.map(\.name).joined(separator: ", ")).",
                startTime: startTime
            )
        }
        let action = dict["action"] as? String ?? ""
        let target = (dict["uri"] as? String) ?? (dict["name"] as? String) ?? ""
        let promptArgs = (dict["arguments"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        let output = await MCPClientManager.shared.resourceAction(
            serverId: server.id, action: action, target: target, arguments: promptArgs
        )
        return Self.mcpResult(output, startTime: startTime)
    }

    func mcpDescribeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let currentAgent = call.currentAgent
        let settings = call.settings
        let startTime = call.startTime
        let query = dict["query"] as? String ?? dict["name"] as? String ?? dict["tool"] as? String ?? ""
        let limit = (dict["limit"] as? Int) ?? Int(dict["limit"] as? String ?? "") ?? MCPToolSearch.defaultLimit
        let live = await MCPClientManager.shared.cachedMcpToolDefs().filter {
            SubAgentExecutor.agentAllowsMCP(toolId: $0.id, toolName: $0.name, agent: currentAgent, settings: settings)
        }
        let found = MCPToolSearch.match(query: query, in: live, limit: limit)
        guard !found.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "No MCP tool matches '\(query)'. \(live.isEmpty ? "No MCP tools are connected." : "Try fewer or different words, or a server id.")",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        return ToolExecutionResult(
            success: true,
            output: "\(found.count) tool(s) loaded; call them directly by these names.\n\n" + MCPToolSearch.describe(found),
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func mcpCallTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        // No default server: dispatching to a guessed server runs the wrong tool and reports
        // success. An unnamed server with more than one enabled is an error the model can fix.
        let serverName = dict["server"] as? String ?? dict["server_name"] as? String ?? ""
        let targetTool = dict["tool"] as? String
            ?? dict["tool_name"] as? String
            ?? dict["action"] as? String
            ?? ""
        let enabled = settings.mcpServers.filter(\.isEnabled)

        guard !targetTool.isEmpty else {
            let names = enabled.map(\.name).joined(separator: ", ")
            return Self.mcpFailure(
                """
                mcp_call needs tool=<an exact tool name>. Nothing was executed. \
                Enabled MCP servers: \(names.isEmpty ? "none" : names). Prefer calling the \
                namespaced tool from your tool list directly (mcp__<serverId>__<tool>).
                """,
                startTime: startTime
            )
        }

        let advertised = await MCPClientManager.shared.advertisedToolNames()
        switch MCPToolRouting.resolveServer(
            requested: serverName,
            toolName: targetTool,
            enabled: enabled,
            advertised: advertised
        ) {
        case .resolved(let server):
            let args = dict["arguments"] as? [String: Any]
                ?? dict["parameters"] as? [String: Any]
                ?? dict
            let output = await MCPClientManager.shared.dispatchToolCall(
                serverConfig: server,
                serverIdentifier: server.name,
                toolName: targetTool,
                arguments: args,
                workspace: workspace
            )
            return Self.mcpResult(output, startTime: startTime)
        case .failed(let message):
            return Self.mcpFailure(message, startTime: startTime)
        }
    }
}
