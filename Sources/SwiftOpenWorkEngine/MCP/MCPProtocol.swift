import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// MARK: - MCP Error Types
public enum MCPError: Error, CustomStringConvertible {
    case serverNotRunning(String)
    case jsonParseFailed(Error)
    case toolNotFound(String, String)
    case timeout
    case invalidConfiguration(String)
    case requestFailed(String)
    case serverCrashed(String)
    case creditLimitReached(String)

    public var description: String {
        switch self {
        case .serverNotRunning(let name):
            return "MCP Server '\(name)' is not running. Please start the server first."
        case .jsonParseFailed(let error):
            return "Failed to parse JSON response: \(error.localizedDescription)"
        case .toolNotFound(let server, let tool):
            return "Tool '\(tool)' not found on MCP Server '\(server)'."
        case .timeout:
            return "MCP tool call timed out after 30 seconds."
        case .invalidConfiguration(let message):
            return "Invalid MCP configuration: \(message)"
        case .requestFailed(let message):
            return "MCP request failed: \(message)"
        case .serverCrashed(let name):
            return "MCP Server '\(name)' has crashed. Check logs for details."
        case .creditLimitReached(let server):
            return "MCP Server '\(server)' credit limit reached. Please recharge credits."
        }
    }
}

// MARK: - JSON-RPC 2.0 Structures
public struct MCPRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: Int
    public var method: String
    public var params: [String: AnyCodable]?

    public init(id: Int, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }
}

public struct MCPToolDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let inputSchemaJson: String?

    public init(name: String, description: String? = nil, inputSchemaJson: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchemaJson = inputSchemaJson
    }

    public static func == (lhs: MCPToolDefinition, rhs: MCPToolDefinition) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    /// Build from a tools/list entry, preserving `inputSchema` when present.
    public static func fromToolsListEntry(_ t: [String: Any]) -> MCPToolDefinition {
        let name = t["name"] as? String ?? "tool"
        let desc = t["description"] as? String
        let schemaObj = t["inputSchema"] as? [String: Any] ?? t["input_schema"] as? [String: Any]
        var schemaJson: String?
        if let schemaObj,
           let data = try? JSONSerialization.data(withJSONObject: schemaObj),
           let s = String(data: data, encoding: .utf8) {
            schemaJson = s
        }
        return MCPToolDefinition(name: name, description: desc, inputSchemaJson: schemaJson)
    }
}

/// Radiant-compatible namespaced MCP tool names: `mcp__{serverId}__{toolName}`.
public enum MCPNamespacedTool {
    public static func name(serverId: String, toolName: String) -> String {
        "mcp__\(serverId)__\(toolName)"
    }

    public static func parse(_ name: String) -> (serverId: String, toolName: String)? {
        let parts = name.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        let serverId = parts[1]
        let toolName = parts.dropFirst(2).joined(separator: "__")
        guard !serverId.isEmpty, !toolName.isEmpty else { return nil }
        return (serverId, toolName)
    }

    public static func isNamespaced(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }
}

// MARK: - Argument Normalization (from GrizzyClaw & Osaurus)
public enum MCPToolArgumentDefaults {
    /// Normalizes tool call arguments and injects required defaults
    public static func normalizeArguments(
        serverName: String,
        toolName: String,
        arguments: [String: Any]
    ) -> [String: Any] {
        var result = coerceJSONMaps(in: arguments)

        // Unpack nested parameter wrappers (but keep MacUse meta-tool shape intact).
        let leaf = toolName.lowercased()
        let isCallByName = leaf == "call_tool_by_name" || leaf == "call_tool"
        if isCallByName {
            // Local models often emit `"arguments": "{}"` (string). MacUse requires a map.
            if result["arguments"] == nil {
                result["arguments"] = [String: Any]()
            } else if let s = result["arguments"] as? String {
                result["arguments"] = parseObjectMap(s) ?? [String: Any]()
            } else if !(result["arguments"] is [String: Any]) {
                result["arguments"] = [String: Any]()
            }
            if let params = result["parameters"] as? String {
                result["parameters"] = parseObjectMap(params) ?? [String: Any]()
            }
        } else if leaf != "get_tool_definitions" {
            if let params = result["parameters"] as? [String: Any] {
                for (k, v) in params { if result[k] == nil { result[k] = v } }
            }
            if let innerArgs = result["arguments"] as? [String: Any] {
                for (k, v) in innerArgs { if result[k] == nil { result[k] = v } }
            }
        }
        // get_tool_definitions: leave `{names:[...]}` alone — do NOT inject empty `arguments`.

        let sLower = serverName.lowercased()
        let tLower = toolName.lowercased()

        // MacUse Low Context Mode default argument shims
        if tLower == "get_tool_definitions"
            || sLower.contains("macuse")
            || tLower.contains("macuse") {
            if tLower == "get_tool_definitions" {
                // `names` is a list. Models routinely pass a bare string, which the server
                // rejects with "expected a sequence" — observed costing a real turn a wasted
                // step. Coerce rather than let a well-formed intent fail on shape.
                if let single = result["names"] as? String {
                    let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
                    result["names"] = trimmed.isEmpty ? ["*"] : [trimmed]
                } else if result["names"] == nil || (result["names"] as? [Any])?.isEmpty == true {
                    result["names"] = ["*"]
                }
            }
        }

        return result
    }

    /// Recursively turn JSON-string maps into real dictionaries (MLX/tool-call footgun).
    public static func coerceJSONMaps(in arguments: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in arguments {
            result[key] = coerceValue(value)
        }
        return result
    }

    private static func coerceValue(_ value: Any) -> Any {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let obj = parseObjectMap(trimmed) {
                return obj
            }
            if trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return arr.map { coerceValue($0) }
            }
            return s
        }
        if let dict = value as? [String: Any] {
            return coerceJSONMaps(in: dict)
        }
        if let arr = value as? [Any] {
            return arr.map { coerceValue($0) }
        }
        return value
    }

    public static func parseObjectMap(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return coerceJSONMaps(in: obj)
    }

    /// Encode a MacUse `call_tool_by_name` payload with a real object for `arguments`.
    public static func macUseCallArgsJSON(toolName: String, arguments: [String: Any] = [:]) -> String {
        let payload: [String: Any] = [
            "name": toolName,
            "arguments": arguments
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else {
            return #"{"name":"\#(toolName)","arguments":{}}"#
        }
        return s
    }

    /// MacUse results often include `actions: [{ tool_call: { tool, arguments } }]`.
    /// Radiant-quality local loops execute those next instead of hoping the model continues.
    public static func suggestedCalls(fromToolResult text: String) -> [(nestedTool: String, arguments: [String: Any])] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let actions = (root["actions"] as? [[String: Any]]) ?? []
        var out: [(String, [String: Any])] = []
        for action in actions {
            guard let tc = action["tool_call"] as? [String: Any] else { continue }
            let nested = (tc["tool"] as? String)
                ?? (tc["name"] as? String)
                ?? ((tc["arguments"] as? [String: Any])?["name"] as? String)
            guard let nested, !nested.isEmpty else { continue }
            var args: [String: Any] = [:]
            if let a = tc["arguments"] as? [String: Any] {
                // Shape A: { tool: mail_search_messages, arguments: { limit: 50 } }
                // Shape B: { tool: call_tool_by_name, arguments: { name, arguments } }
                if nested == "call_tool_by_name" || nested == "call_tool",
                   let innerName = a["name"] as? String {
                    let innerArgs = (a["arguments"] as? [String: Any]) ?? [:]
                    out.append((innerName, coerceJSONMaps(in: innerArgs)))
                    continue
                }
                if a["name"] != nil && nested.hasPrefix("mail_") == false {
                    // Nested call_tool_by_name style without rewriting nested name above.
                    if let innerName = a["name"] as? String {
                        let innerArgs = (a["arguments"] as? [String: Any]) ?? [:]
                        out.append((innerName, coerceJSONMaps(in: innerArgs)))
                        continue
                    }
                }
                args = coerceJSONMaps(in: a)
            } else if let s = tc["arguments"] as? String {
                args = parseObjectMap(s) ?? [:]
            }
            out.append((nested, args))
        }
        return out
    }
}

// MARK: - Server Health Status
public enum MCPServerStatus: Sendable, Equatable {
    case notStarted, connecting, running, crashed, unreachable
}

/// Radiant-style status row for Settings / agent inventory (connected, error, tool names).
public struct MCPServerReport: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var connected: Bool
    public var status: MCPServerStatus
    public var error: String?
    public var toolCount: Int
    public var tools: [String]
    public var transport: String
    public var detail: String
}

private enum MCPLaunchError: LocalizedError {
    case processExited(String)

    var errorDescription: String? {
        switch self {
        case .processExited(let message): return message
        }
    }
}

/// Resumes a continuation at most once — used so MCP deadlines never wait on hung children.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var value: T?
    private var resumed = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        self.value = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class MCPAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    /// Returns the value after decrement.
    @discardableResult
    func decrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value -= 1
        return value
    }
}

// MARK: - Live MCP Client & Manager
public actor MCPClientManager {
    public static let shared = MCPClientManager()

    private var runningProcesses: [String: Process] = [:]
    private var processOutputPipes: [String: Pipe] = [:]
    private var processInputPipes: [String: Pipe] = [:]
    /// Thread-safe stdout accumulators fed by FileHandle readability handlers (actor-safe across awaits).
    private var processOutputBuffers: [String: MCPStdioBuffer] = [:]
    private var discoveredTools: [String: [MCPToolDefinition]] = [:]
    private var serverStatus: [String: MCPServerStatus] = [:]
    private var serverErrors: [String: String] = [:]
    private var sdkSessions: [String: MCPSDKSession] = [:]
    /// Bumps on each start/stop so a late connect after timeout cannot mark the server running.
    private var startGenerations: [String: Int] = [:]
    private var requestId: Int = 1
    
    // Request throttling for concurrent execution control
    private var pendingRequests = 0
    private let maxConcurrentRequests = 3

    private init() {}

    // MARK: - Request ID Generation
    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    // MARK: - Discover & Start Server
    public func startServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        if config.transportType == .stdio {
            return try await startStdioServer(config: config)
        } else {
            return try await queryHttpSseServer(config: config)
        }
    }

    public func discoverAllTools() async -> [String: [MCPToolDefinition]] {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabled = loadedSettings.mcpServers.filter { $0.isEnabled }
        var result: [String: [MCPToolDefinition]] = [:]

        for server in enabled {
            do {
                let tools = try await startServer(config: server)
                result[server.name] = tools
            } catch {
                serverStatus[server.id] = .crashed
                serverErrors[server.id] = error.localizedDescription
                result[server.name] = []
            }
        }
        return result
    }

    /// Snapshot of already-discovered MCP tools (no process starts). Safe for casual chat turns.
    public func cachedMcpToolDefs() -> [Tool] {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabled = loadedSettings.mcpServers.filter(\.isEnabled)
        return buildToolModels(from: enabled, order: enabled)
    }

    /// Warm enabled servers in the background so the next tool turn is faster.
    public func warmAllInBackground(perServerTimeout: Duration = .seconds(8)) {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabled = loadedSettings.mcpServers.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        Task { await self.warmServers(enabled, perServerTimeout: perServerTimeout) }
    }

    /// Radiant `mcpStatus` parity — settings UI and “what MCP servers are available?” answers.
    public func mcpStatusReports(probe: Bool = false, perServerTimeout: Duration = .seconds(8)) async -> [MCPServerReport] {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let servers = loadedSettings.mcpServers
        if probe {
            let enabled = servers.filter(\.isEnabled)
            await raceDeadline(overallTimeout: perServerTimeout) {
                await self.warmServers(enabled, perServerTimeout: perServerTimeout)
            }
        }
        return servers.map { server in
            let tools = discoveredTools[server.id] ?? []
            let status = serverStatus[server.id] ?? .notStarted
            let err = serverErrors[server.id]
            let connected = status == .running && err == nil
            let detail: String
            if server.transportType == .stdio {
                detail = "\(server.command) \(server.args.joined(separator: " "))".trimmingCharacters(in: .whitespaces)
            } else {
                detail = server.url
            }
            return MCPServerReport(
                id: server.id,
                name: server.name,
                enabled: server.isEnabled,
                connected: connected,
                status: status,
                error: err,
                toolCount: tools.count,
                tools: tools.map(\.name),
                transport: server.transportType.displayName,
                detail: detail
            )
        }
    }

    /// Prompt block listing configured servers (no process spawn). Used for inventory questions.
    public nonisolated static func configuredServersPromptSummary(servers: [MCPServerConfig]) -> String {
        guard !servers.isEmpty else {
            return """

            ### Configured MCP servers
            None configured. Add servers in Settings → MCP.
            """
        }
        let lines = servers.map { s -> String in
            let state = s.isEnabled ? "enabled" : "disabled"
            let endpoint: String
            if s.transportType == .stdio {
                endpoint = "`\(s.command) \(s.args.joined(separator: " "))`".trimmingCharacters(in: .whitespaces)
            } else {
                endpoint = "`\(s.url)`"
            }
            return "- **\(s.name)** (\(s.id)) — \(state), \(s.transportType.displayName): \(endpoint)"
        }
        return """

        ### Configured MCP servers
        \(lines.joined(separator: "\n"))
        Answer inventory questions from this list. Live tool schemas appear as `mcp__{serverId}__{tool}` once a server connects.
        """
    }

    /// True when the user is asking which MCP servers exist / are configured — no connect required.
    public nonisolated static func isMCPInventoryPrompt(_ prompt: String) -> Bool {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mentionsMCP = p.contains("mcp")
        guard mentionsMCP else { return false }

        // Inventory mode removes every tool and asks for a one-table answer, so it must only ever
        // catch a *question about* the servers — never a task that *uses* one.
        //
        // It used to match any prompt mentioning "mcp" beside a word like "configured" or
        // "mcp-server", whatever its length. The MorningBrief automation — eight steps, one of
        // them "if an email MCP tool is configured, always use the macuse mcp-server" — ran with
        // no tools every morning and answered with a table saying it was "restricted from calling
        // tools". The README's own example, "use the macuse mcp-server and check the mail", did
        // the same.
        guard p.count <= 120 else { return false }
        let usesAServer = [
            "use ", "using ", "via ", "through ", "call ", "run ", "send ", "read ", "open ",
            "mail", "calendar", "reminder", "message", "note", "create", "write", "summar", "search", "fetch"
        ]
        if usesAServer.contains(where: { p.contains($0) }) { return false }
        let inventoryHints = [
            "available", "configured", "what mcp", "which mcp", "list mcp",
            "mcp server", "mcp-server", "show mcp", "see what mcp", "check.*mcp"
        ]
        if inventoryHints.contains(where: { hint in
            if hint.contains(".*") {
                return p.range(of: hint, options: .regularExpression) != nil
            }
            return p.contains(hint)
        }) {
            return true
        }
        // Short “check mcp servers” / “mcp servers?” style prompts.
        if p.count <= 80, (p.contains("server") || p.contains("servers")),
           (p.contains("check") || p.contains("list") || p.contains("show") || p.contains("what") || p.contains("see")) {
            return true
        }
        return false
    }

    /// Radiant-style first-class MCP tools for the agent loop:
    /// `mcp__{serverId}__{toolName}` with real JSON schemas from tools/list.
    ///
    /// Cache-first and deadline-safe: never waits on hung `client.connect` children
    /// (structured `TaskGroup` timeouts cannot return while children ignore cancellation).
    public func mcpToolDefs(
        preferServerIds: [String] = [],
        perServerTimeout: Duration = .seconds(8),
        overallTimeout: Duration = .seconds(6),
        blockForWarm: Bool = false
    ) async -> [Tool] {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabled = loadedSettings.mcpServers.filter { $0.isEnabled }
        guard !enabled.isEmpty else { return [] }

        let preferred: [MCPServerConfig]
        let deferred: [MCPServerConfig]
        if preferServerIds.isEmpty {
            preferred = enabled
            deferred = []
        } else {
            let preferSet = Set(preferServerIds)
            let matched = enabled.filter { preferSet.contains($0.id) || preferSet.contains($0.name) }
            if matched.isEmpty {
                preferred = enabled
                deferred = []
            } else {
                preferred = matched
                deferred = enabled.filter { server in !matched.contains(where: { $0.id == server.id }) }
            }
        }

        let cached = buildToolModels(from: enabled, order: preferred + deferred)
        if !blockForWarm {
            // Radiant-better: never stall the chat bubble on npx cold starts.
            Task {
                await self.warmServers(preferred, perServerTimeout: perServerTimeout)
                if !deferred.isEmpty {
                    let timeout = perServerTimeout
                    await self.warmServers(deferred, perServerTimeout: timeout)
                }
            }
            return cached
        }

        await raceDeadline(overallTimeout: overallTimeout) {
            await self.warmServers(preferred, perServerTimeout: perServerTimeout)
            if !deferred.isEmpty {
                let timeout = perServerTimeout
                Task { await self.warmServers(deferred, perServerTimeout: timeout) }
            }
        }
        return buildToolModels(from: enabled, order: preferred + deferred)
    }

    /// Wait until `work` finishes or `overallTimeout` elapses — whichever first.
    /// Unlike `withTaskGroup`, this does **not** wait for cancelled children to exit.
    private func raceDeadline(overallTimeout: Duration, work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceResume(cont)
            Task {
                await work()
                once.resume(())
            }
            Task {
                try? await Task.sleep(for: overallTimeout)
                once.resume(())
            }
        }
    }

    private func buildToolModels(from enabled: [MCPServerConfig], order: [MCPServerConfig]) -> [Tool] {
        // `order` is a preference, not a filter — append any enabled server it leaves out.
        var sequence = order.isEmpty ? enabled : order
        let ordered = Set(sequence.map(\.id))
        sequence.append(contentsOf: enabled.filter { !ordered.contains($0.id) })

        var result: [Tool] = []
        var seenServerIds = Set<String>()
        for server in sequence where seenServerIds.insert(server.id).inserted {
            for def in discoveredTools[server.id] ?? [] {
                // A tool the user switched off is not advertised to the model at all.
                guard MCPToolGate.isToolEnabled(server: server, toolName: def.name) else { continue }
                result.append(toolModel(server: server, def: def))
            }
        }
        return result
    }

    private func toolModel(server: MCPServerConfig, def: MCPToolDefinition) -> Tool {
        let namespaced = MCPNamespacedTool.name(serverId: server.id, toolName: def.name)
        let effect = MCPEffectCatalog.classify(server: server, toolName: def.name, advertised: true)
        return Tool(
            id: namespaced,
            name: namespaced,
            displayName: "\(server.name): \(def.name)",
            description: "[\(server.name)] \(def.description ?? def.name)",
            category: .mcp,
            parametersJsonSchema: def.inputSchemaJson ?? #"{"type":"object","properties":{}}"#,
            isEnabled: true,
            requiresApproval: effect == .write
        )
    }

    /// Advertised tool names per server id, for routing and effect classification.
    public func advertisedToolNames() -> [String: [String]] {
        discoveredTools.mapValues { $0.map(\.name) }
    }

    public func advertisedToolNames(serverId: String) -> [String] {
        (discoveredTools[serverId] ?? []).map(\.name)
    }

    private func warmServers(_ servers: [MCPServerConfig], perServerTimeout: Duration) async {
        guard !servers.isEmpty else { return }
        // Detached per-server races — do not use a parent TaskGroup that waits on hung connects.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceResume(cont)
            let total = servers.count
            let remaining = MCPAtomicCounter(total)
            if total == 0 {
                once.resume(())
                return
            }
            for server in servers {
                Task {
                    await self.ensureServerReady(server, timeout: perServerTimeout)
                    if remaining.decrement() == 0 {
                        once.resume(())
                    }
                }
            }
            // Hard ceiling: all per-server budgets in parallel, plus a small grace.
            Task {
                try? await Task.sleep(for: perServerTimeout + .milliseconds(500))
                once.resume(())
            }
        }
    }

    private func ensureServerReady(_ server: MCPServerConfig, timeout: Duration = .seconds(8)) async {
        if Task.isCancelled { return }
        if case .running = serverStatus[server.id],
           let cached = discoveredTools[server.id], !cached.isEmpty {
            return
        }
        serverStatus[server.id] = .connecting
        serverErrors[server.id] = nil

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceResume(cont)
            let serverId = server.id
            let name = server.name

            Task {
                do {
                    _ = try await self.startServer(config: server)
                } catch {
                    self.noteStartFailure(serverId: serverId, message: error.localizedDescription)
                }
                once.resume(())
            }
            Task {
                try? await Task.sleep(for: timeout)
                // Kill in-flight process/session so a hung SDK connect can unwind.
                await self.timeoutStart(serverId: serverId, name: name, timeout: timeout)
                once.resume(())
            }
        }
    }

    private func noteStartFailure(serverId: String, message: String) {
        if serverStatus[serverId] == .running { return }
        serverStatus[serverId] = .crashed
        serverErrors[serverId] = message
        print("[MCPManager] Start failed for \(serverId): \(message)")
    }

    private func timeoutStart(serverId: String, name: String, timeout: Duration) async {
        if case .running = serverStatus[serverId],
           let cached = discoveredTools[serverId], !cached.isEmpty {
            return
        }
        await stopServer(id: serverId)
        serverStatus[serverId] = .crashed
        serverErrors[serverId] = "Timed out after \(timeout) starting \(name)"
        print("[MCPManager] Timed out starting \(name) after \(timeout)")
    }

    /// Match user intent to MCP server ids so we do not block the first token on every `npx` server.
    public nonisolated static func preferredServerIds(
        forPrompt prompt: String,
        servers: [MCPServerConfig]
    ) -> [String] {
        let p = prompt.lowercased()
        // Inventory questions do not need a live connect preference.
        if isMCPInventoryPrompt(prompt) { return [] }

        let enabled = servers.filter(\.isEnabled)
        func match(_ predicates: [(MCPServerConfig) -> Bool]) -> [String] {
            enabled.filter { server in predicates.contains { $0(server) } }.map(\.id)
        }

        let macuseIntent = p.contains("macuse") || p.contains("mac use")
            || ((p.contains("mail") || p.contains("email") || p.contains("inbox") || p.contains("calendar"))
                && (p.contains("mcp") || p.contains("computer") || p.contains("this computer")))
        if macuseIntent {
            let ids = match([
                { $0.name.lowercased().contains("macuse") },
                { $0.command.lowercased().contains("macuse") }
            ])
            if !ids.isEmpty { return ids }
        }

        if p.contains("codegraph") {
            let ids = match([
                { $0.name.lowercased().contains("codegraph") },
                { $0.command.lowercased().contains("codegraph") }
            ])
            if !ids.isEmpty { return ids }
        }

        // No strong preference — warm everything in the background.
        return []
    }

    /// Greetings / short social turns should not wait on MCP cold starts.
    public nonisolated static func isCasualChatPrompt(_ prompt: String) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return true }
        let exact: Set<String> = [
            "hi", "hello", "hey", "yo", "sup", "howdy", "hiya",
            "good morning", "good afternoon", "good evening", "good night",
            "morning", "gm", "thanks", "thank you", "thx", "ty",
            "ok", "okay", "k", "cool", "great", "nice", "bye", "goodbye"
        ]
        if exact.contains(t) { return true }
        if t.count <= 40 {
            let prefixes = ["hi ", "hello ", "hey ", "good morning", "good afternoon", "good evening"]
            if prefixes.contains(where: { t.hasPrefix($0) }) {
                let actionHints = ["mcp", "mail", "email", "file", "code", "search", "run", "tool", "check", "list", "open", "write", "fix"]
                if !actionHints.contains(where: { t.contains($0) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Resolve the MCP `tools/call` name + arguments.
    /// MacUse exposes only meta-tools (`get_tool_definitions`, `call_tool_by_name`); nested
    /// `name`/`arguments` must stay as parameters — do not unwrap them into a fake top-level tool.
    public nonisolated static func resolveMCPCall(
        toolName: String,
        arguments: [String: Any]
    ) -> (name: String, arguments: [String: Any]) {
        let leaf = toolName.lowercased()
        if leaf == "call_tool_by_name" || leaf == "call_tool" || leaf == "get_tool_definitions" {
            return (toolName, arguments)
        }

        var actualTool = arguments["action"] as? String
            ?? arguments["tool"] as? String
            ?? arguments["name"] as? String
            ?? toolName
        // Models often emit `codegraph_call` with nested `{tool: ...}` — unwrap that.
        if actualTool.lowercased().hasSuffix("_call"),
           let nested = arguments["tool"] as? String,
           !nested.isEmpty,
           nested.lowercased() != actualTool.lowercased() {
            actualTool = nested
        }
        let callArgs = arguments["parameters"] as? [String: Any]
            ?? arguments["arguments"] as? [String: Any]
            ?? arguments.filter {
                !["action", "tool", "name", "server", "server_name", "parameters", "arguments"].contains($0.key)
            }
        return (actualTool, callArgs)
    }
    
    public func getServerStatus(serverId: String) -> MCPServerStatus {
        serverStatus[serverId] ?? .notStarted
    }
    
    public func getAllServerStatuses() -> [String: MCPServerStatus] {
        serverStatus
    }

    private func startStdioServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        await stopServer(id: config.id)
        let generation = (startGenerations[config.id] ?? 0) + 1
        startGenerations[config.id] = generation
        serverStatus[config.id] = .connecting
        serverErrors[config.id] = nil

        // Prefer the official MCP Swift SDK (Radiant parity); fall back to hand-rolled pipes.
        do {
            let session = MCPSDKSession(config: config)
            // Register BEFORE connect so a timeout can kill a hung handshake.
            sdkSessions[config.id] = session
            let tools = try await session.start()
            guard startGenerations[config.id] == generation else {
                await session.stop()
                throw MCPError.timeout
            }
            discoveredTools[config.id] = tools
            serverStatus[config.id] = .running
            serverErrors[config.id] = nil
            return tools
        } catch {
            if sdkSessions[config.id] != nil {
                await sdkSessions[config.id]?.stop()
                sdkSessions.removeValue(forKey: config.id)
            }
            print("[MCPManager] SDK start failed for \(config.name), falling back to hand-rolled: \(error.localizedDescription)")
        }

        guard startGenerations[config.id] == generation else {
            throw MCPError.timeout
        }

        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        // Never attach an unread stderr Pipe — MCP servers (node/python) log heavily to stderr and
        // will deadlock once the ~64KB pipe buffer fills, freezing the app mid tool-call.
        process.standardError = FileHandle.nullDevice

        let env = ToolExecutionEngine.defaultEnvironment(custom: config.env)
        let launchArgs = Self.sanitizedStdioArgs(command: config.command, name: config.name, args: config.args)
        let resolved = Self.resolveExecutable(config.command, environment: env)
        if resolved.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = launchArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [config.command] + launchArgs
        }

        if !config.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        }

        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe

        let stdoutBuffer = MCPStdioBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdoutBuffer.append(chunk)
            }
        }

        do {
            try process.run()
            // Bad CLI args (e.g. codegraph `alwaysLoad true`) exit immediately — writing stdin then
            // used to raise an uncaught NSException via FileHandle.write(_:) and kill the app.
            try await Task.sleep(nanoseconds: 120_000_000)
            guard process.isRunning else {
                outPipe.fileHandleForReading.readabilityHandler = nil
                throw MCPLaunchError.processExited(
                    "MCP '\(config.name)' exited immediately. Check command/args (got: \(config.command) \(launchArgs.joined(separator: " ")))."
                )
            }
            guard startGenerations[config.id] == generation else {
                outPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                throw MCPError.timeout
            }

            runningProcesses[config.id] = process
            processInputPipes[config.id] = inPipe
            processOutputPipes[config.id] = outPipe
            processOutputBuffers[config.id] = stdoutBuffer

            // 1. Send initialize
            let initRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "clientInfo": ["name": "SwiftOpenWork", "version": "1.0.0"]
                ]
            ]
            try sendJson(initRequest, to: inPipe)
            guard process.isRunning else {
                throw MCPLaunchError.processExited("MCP '\(config.name)' died during initialize.")
            }

            // 2. Send initialized notification
            let initializedNotification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ]
            try sendJson(initializedNotification, to: inPipe)

            // 3. Send tools/list and wait for response to discover real tools
            let listToolsRequest: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [:]
            ]
            try sendJson(listToolsRequest, to: inPipe)

            var tools: [MCPToolDefinition] = []
            // Cap tools/list wait; outer ensureServerReady also kills the process on deadline.
            let listResp = await readResponse(for: 2, buffer: stdoutBuffer, timeoutSeconds: 8.0)
            if !listResp.isEmpty, let data = listResp.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let toolsArray = (json["tools"] as? [[String: Any]]) ?? ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
                for t in toolsArray {
                    tools.append(MCPToolDefinition.fromToolsListEntry(t))
                }
            }

            guard process.isRunning else {
                throw MCPLaunchError.processExited("MCP '\(config.name)' exited after handshake.")
            }
            guard startGenerations[config.id] == generation else {
                throw MCPError.timeout
            }

            serverStatus[config.id] = .running
            serverErrors[config.id] = nil
            discoveredTools[config.id] = tools
            return tools
        } catch {
            print("[MCPManager] Stdio start failed for \(config.name): \(error.localizedDescription)")
            outPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            runningProcesses.removeValue(forKey: config.id)
            processInputPipes.removeValue(forKey: config.id)
            processOutputPipes.removeValue(forKey: config.id)
            processOutputBuffers.removeValue(forKey: config.id)
            if startGenerations[config.id] == generation {
                serverStatus[config.id] = .crashed
                serverErrors[config.id] = error.localizedDescription
                discoveredTools[config.id] = []
            }
            throw error
        }
    }

    /// Drop invalid CodeGraph argv tokens. See `MCPServerConfig.sanitizedStdioArgs`.
    public static func sanitizedStdioArgs(command: String, name: String, args: [String]) -> [String] {
        MCPServerConfig.sanitizedStdioArgs(command: command, name: name, args: args)
    }

    public static func resolveExecutable(_ command: String, environment: [String: String]) -> String {
        if command.contains("/"), FileManager.default.isExecutableFile(atPath: command) {
            return command
        }
        let pathDirs = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return command
    }

    private func queryHttpSseServer(config: MCPServerConfig) async throws -> [MCPToolDefinition] {
        guard let url = URL(string: config.url), !config.url.isEmpty else {
            serverStatus[config.id] = .unreachable
            serverErrors[config.id] = "Missing or invalid URL for HTTP MCP server."
            return []
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        // Radiant parity: optional bearer token via env["MCP_TOKEN"] / env["token"] / headers.
        if req.value(forHTTPHeaderField: "Authorization") == nil {
            if let token = config.env["MCP_TOKEN"] ?? config.env["token"] ?? config.env["TOKEN"], !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 6

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                serverStatus[config.id] = .unreachable
                serverErrors[config.id] = "No HTTP response from \(config.url)"
                discoveredTools[config.id] = []
                return []
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                serverStatus[config.id] = .unreachable
                let msg = config.headers["Authorization"] != nil || config.env["MCP_TOKEN"] != nil
                    ? "That server rejected the token — check it is current and has the right scope."
                    : "That server needs you to sign in. Paste an access token in headers/env; SwiftOpenWork cannot yet do a full OAuth sign-in for MCP servers."
                serverErrors[config.id] = msg
                discoveredTools[config.id] = []
                return []
            }
            guard (200...299).contains(http.statusCode) else {
                serverStatus[config.id] = .unreachable
                serverErrors[config.id] = "HTTP \(http.statusCode) from \(config.url)"
                discoveredTools[config.id] = []
                return []
            }

            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = dict["result"] as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                var list: [MCPToolDefinition] = []
                for t in toolsArray {
                    list.append(MCPToolDefinition.fromToolsListEntry(t))
                }
                serverStatus[config.id] = .running
                serverErrors[config.id] = nil
                discoveredTools[config.id] = list
                return list
            }
            serverStatus[config.id] = .unreachable
            serverErrors[config.id] = "Unexpected tools/list payload from \(config.url)"
        } catch {
            serverStatus[config.id] = .unreachable
            serverErrors[config.id] = error.localizedDescription
        }

        discoveredTools[config.id] = []
        return []
    }

    // MARK: - Universal Tool Dispatcher
    /// Run an MCP tool and return text for the model.
    ///
    /// Transient transport failures are retried once here rather than costing the model a step,
    /// and every failed result carries a recovery hint so the next step is a fix instead of a
    /// verbatim retry.
    public func dispatchToolCall(
        serverConfig: MCPServerConfig? = nil,
        serverIdentifier: String? = nil,
        toolName: String,
        arguments: [String: Any],
        workspace: Workspace
    ) async -> String {
        var output = await dispatchToolCallOnce(
            serverConfig: serverConfig,
            serverIdentifier: serverIdentifier,
            toolName: toolName,
            arguments: arguments,
            workspace: workspace
        )

        if MCPFailureClassifier.failed(text: output),
           MCPFailureClassifier.isTransientFailure(output) {
            try? await Task.sleep(for: .milliseconds(400))
            let retry = await dispatchToolCallOnce(
                serverConfig: serverConfig,
                serverIdentifier: serverIdentifier,
                toolName: toolName,
                arguments: arguments,
                workspace: workspace
            )
            // Keep the retry only if it actually did better.
            if !MCPFailureClassifier.failed(text: retry) {
                return retry
            }
            output = retry
        }

        return MCPFailureClassifier.annotate(output)
    }

    private func dispatchToolCallOnce(
        serverConfig: MCPServerConfig? = nil,
        serverIdentifier: String? = nil,
        toolName: String,
        arguments: [String: Any],
        workspace: Workspace
    ) async -> String {
        let loadedSettings = PersistenceManager.shared.loadSettings()
        let enabledServers = loadedSettings.mcpServers.filter(\.isEnabled)
        let advertised = advertisedToolNames()

        // 1. Identify the target server. An ambiguous or unknown identifier is an error, not a
        //    guess — dispatching to the wrong server produces confident, wrong answers.
        var targetServer: MCPServerConfig? = serverConfig
        if targetServer == nil {
            let requested = serverIdentifier
                ?? arguments["server"] as? String
                ?? arguments["server_name"] as? String
                ?? ""
            switch MCPToolRouting.resolveServer(
                requested: requested,
                toolName: toolName,
                enabled: enabledServers,
                advertised: advertised
            ) {
            case .resolved(let server):
                targetServer = server
            case .failed(let message):
                return message
            }
        }

        guard let resolvedServer = targetServer else {
            // Same wording the dispatcher uses for an unknown tool — one definition, in
            // `ToolCallRepair`, so the two paths cannot drift apart again.
            let summary = enabledServers.isEmpty
                ? nil
                : enabledServers.map { "\($0.name) (`\($0.id)`)" }.joined(separator: ", ")
            return ToolCallRepair.unknownToolMessage(toolName, mcpServerSummary: summary)
        }

        let sName = resolvedServer.name
        let normArgs = MCPToolArgumentDefaults.normalizeArguments(
            serverName: sName,
            toolName: toolName,
            arguments: arguments
        )

        // 2. Per-tool gate: a tool the user switched off must not run, and the model needs to be
        //    told so it can route around it instead of retrying.
        let gateTarget = Self.resolveMCPCall(toolName: toolName, arguments: normArgs).name
        if !MCPToolGate.isToolEnabled(server: resolvedServer, toolName: gateTarget) {
            return MCPToolGate.disabledMessage(server: resolvedServer, toolName: gateTarget)
        }

        // Verify the tool exists before sending a doomed call, but only once the server has
        // actually reported a catalog — an empty list means "not discovered yet", not "no tools".
        let serverTools = advertised[resolvedServer.id] ?? []
        if !serverTools.isEmpty,
           MCPToolRouting.canonicalTool(gateTarget, known: serverTools) == nil,
           !MCPEffectCatalog.universalReadTools.contains(gateTarget) {
            return MCPToolRouting.unknownToolMessage(
                tool: gateTarget,
                server: resolvedServer,
                advertised: serverTools
            )
        }

        // 3. Dispatch JSON-RPC 2.0 tools/call over the server's transport.
        do {
            let server = resolvedServer
            // Check server health before attempting call
            let status = getServerStatus(serverId: server.id)
            if case .crashed = status {
                let err = serverErrors[server.id].map { ": \($0)" } ?? "."
                return """
                Error: MCP server '\(server.name)' has crashed and did not run '\(toolName)'\(err) \
                Do not retry this call. Use a different tool, or tell the user the server needs \
                restarting from Settings → Tools & MCP.
                """
            }

            if server.transportType == .stdio && !server.command.isEmpty {
                let hasSDK = sdkSessions[server.id] != nil
                let procRunning = runningProcesses[server.id]?.isRunning == true
                if !hasSDK && !procRunning {
                    _ = try? await startStdioServer(config: server)
                }

                // Official SDK path (Radiant parity)
                if let session = sdkSessions[server.id] {
                    let resolved = Self.resolveMCPCall(toolName: toolName, arguments: normArgs)
                    do {
                        // Deliberately unbounded: the agent loop bounds what reaches the
                        // transcript, but catalog payloads are parsed structurally first. Cutting
                        // a 40KB tools/list to head+tail yields invalid JSON, which silently
                        // downgrades promotion to scraping names out of prose.
                        return try await session.callTool(name: resolved.name, arguments: JSONCopy.fresh(resolved.arguments))
                    } catch {
                        return "Error: MCP SDK call to '\(server.name)'/\(resolved.name) failed: \(error.localizedDescription)"
                    }
                }

                guard let proc = runningProcesses[server.id], proc.isRunning else {
                    return "Error: MCP Server '\(server.name)' failed to start. If this is CodeGraph, args must be `serve --mcp` (not `alwaysLoad true`)."
                }

                // Verify process is now running
                if let inPipe = processInputPipes[server.id],
                   let stdoutBuffer = processOutputBuffers[server.id] {
                    let reqId = nextRequestId()
                    let resolved = Self.resolveMCPCall(toolName: toolName, arguments: normArgs)
                    let actualTool = resolved.name
                    let callArgs = resolved.arguments

                    if !acquireRequestSlot() {
                        return "MCP Server '\(server.name)' is busy. Please wait and retry your request."
                    }

                    // `list_tools` is an MCP protocol method (tools/list), not a tools/call target.
                    let listAliases: Set<String> = ["list_tools", "tools_list", "list-tools", "tools/list", "listtools"]
                    let callReq: [String: Any]
                    if listAliases.contains(actualTool.lowercased()) {
                        callReq = [
                            "jsonrpc": "2.0",
                            "id": reqId,
                            "method": "tools/list",
                            "params": [:]
                        ]
                    } else {
                        callReq = [
                            "jsonrpc": "2.0",
                            "id": reqId,
                            "method": "tools/call",
                            "params": [
                                "name": actualTool,
                                "arguments": callArgs
                            ]
                        ]
                    }

                    do {
                        try sendJson(callReq, to: inPipe)
                        let responseText = await self.readResponse(for: reqId, buffer: stdoutBuffer, timeoutSeconds: 30.0)
                        releaseRequestSlot()
                        if !responseText.isEmpty {
                            return responseText
                        }
                        return "MCP Server '\(server.name)' returned an empty response for '\(actualTool)' (timed out or no matching JSON-RPC id)."
                    } catch {
                        releaseRequestSlot()
                        return "Error: failed to send MCP request to '\(server.name)': \(error.localizedDescription)"
                    }
                } else {
                    return "Error: MCP Server '\(server.name)' communication pipes not available."
                }
            } else if server.transportType == .httpSse && !server.url.isEmpty {
                guard let endpoint = URL(string: server.url) else {
                    return "Error: MCP Server '\(server.name)' has an invalid URL: \(server.url)"
                }
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (k, v) in server.headers { req.setValue(v, forHTTPHeaderField: k) }
                for (k, v) in server.env { req.setValue(v, forHTTPHeaderField: k) }

                var actualTool = normArgs["action"] as? String ?? normArgs["tool"] as? String ?? normArgs["name"] as? String ?? toolName
                if actualTool.lowercased().hasSuffix("_call"),
                   let nested = normArgs["tool"] as? String,
                   !nested.isEmpty,
                   nested.lowercased() != actualTool.lowercased() {
                    actualTool = nested
                }
                let callArgs = normArgs["parameters"] as? [String: Any]
                    ?? normArgs["arguments"] as? [String: Any]
                    ?? normArgs.filter { !["action", "tool", "name", "server", "server_name", "parameters", "arguments"].contains($0.key) }
                let listAliases: Set<String> = ["list_tools", "tools_list", "list-tools", "tools/list", "listtools"]
                let callReq: [String: Any]
                if listAliases.contains(actualTool.lowercased()) {
                    callReq = [
                        "jsonrpc": "2.0",
                        "id": nextRequestId(),
                        "method": "tools/list",
                        "params": [:]
                    ]
                } else {
                    callReq = [
                        "jsonrpc": "2.0",
                        "id": nextRequestId(),
                        "method": "tools/call",
                        "params": [
                            "name": actualTool,
                            "arguments": callArgs
                        ]
                    ]
                }
                let bodyData = try? JSONSerialization.data(withJSONObject: callReq)
                req.httpBody = bodyData
                
                do {
                    let (data, response) = try await URLSession.shared.data(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200,
                       let respDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        if let result = respDict["result"] as? [String: Any] {
                            if let content = result["content"] as? [[String: Any]] {
                                let texts = content.compactMap { $0["text"] as? String }
                                if !texts.isEmpty {
                                    return texts.joined(separator: "\n")
                                }
                            }
                            if let tools = result["tools"] as? [[String: Any]] {
                                let names = tools.compactMap { $0["name"] as? String }
                                if !names.isEmpty {
                                    return "Available tools on \(server.name):\n" + names.map { "- \($0)" }.joined(separator: "\n")
                                }
                            }
                            let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? "{}"
                            return jsonText
                        }
                        if let error = respDict["error"] as? [String: Any] {
                            return "MCP Error from '\(server.name)': \(error["message"] as? String ?? "\(error)")"
                        }
                    } else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        return "Error: MCP Server '\(server.name)' returned HTTP \(status)."
                    }
                } catch {
                    return "Error: MCP Server '\(server.name)' request failed: \(error.localizedDescription)"
                }
            }
        }

        // The server resolved but has no usable transport — a misconfiguration, not a call we can
        // quietly substitute something else for. Say so; do not report success.
        let detail: String
        switch resolvedServer.transportType {
        case .stdio:
            detail = "it is configured as stdio but has no command."
        case .httpSse:
            detail = "it is configured as HTTP/SSE but has no URL."
        case .websocket:
            detail = "the WebSocket transport is not implemented yet — reconfigure it as stdio or HTTP/SSE."
        }
        return """
        Error: MCP server '\(sName)' cannot be called because \(detail) Nothing was executed. \
        Fix the server in Settings → Tools & MCP, or use a different tool.
        """
    }

    // MARK: - Timeout Helper
    private func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: (T, Bool)?.self) { group in
            group.addTask {
                let value = await work()
                return (value, true)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            while let nextResult = await group.next() {
                if let (value, _) = nextResult {
                    group.cancelAll()
                    return value
                }
            }
            return await work()
        }
    }

    private func readResponse(for reqId: Int, buffer: MCPStdioBuffer, timeoutSeconds: Double) async -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if let matched = buffer.extractJSONRPCResponse(id: reqId) {
                return matched
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Final attempt after timeout window
        return buffer.extractJSONRPCResponse(id: reqId) ?? ""
    }

    // MARK: - Native macOS Automations (Calendar, Reminders, AppleScript)
    public func executeMacCalendarQuery(arguments: [String: Any]) async -> String {
        let script = """
        tell application "Calendar"
            set today to current date
            set startDate to today - (1 * days)
            set endDate to today + (14 * days)
            set outputList to {}
            try
                repeat with c in calendars
                    set calName to name of c
                    set evs to (every event of c whose start date is greater than or equal to startDate and start date is less than or equal to endDate)
                    repeat with e in evs
                        set evSummary to summary of e
                        set evStart to (start date of e as string)
                        set evEnd to (end date of e as string)
                        set end of outputList to "• " & evSummary & " (" & evStart & " → " & evEnd & ") [Calendar: " & calName & "]"
                    end repeat
                end repeat
            on error errMsg
                return "Calendar Access Note: " & errMsg
            end try
            if (count of outputList) is 0 then
                return "No calendar events scheduled for the next 14 days."
            else
                set AppleScript's text item delimiters to "\n"
                return outputList as text
            end if
        end tell
        """

        let res = await executeAppleScript(script)
        if res.isEmpty || res.contains("Calendar Access Note") {
            return "### macOS Calendar Events:\n- Checked macOS Calendar. No upcoming conflicts or events found for the requested period (or Calendar permissions needed in macOS System Settings > Privacy > Calendars)."
        }
        return "### macOS Calendar Events (via MacUse):\n\(res)"
    }

    public func executeMacRemindersQuery(arguments: [String: Any]) async -> String {
        let script = """
        tell application "Reminders"
            set outputList to {}
            try
                repeat with l in lists
                    set listName to name of l
                    set rems to (every reminder of l whose completed is false)
                    repeat with r in rems
                        set rName to name of r
                        set end of outputList to "• [ ] " & rName & " (" & listName & ")"
                    end repeat
                end repeat
            on error errMsg
                return "Reminders Access Note: " & errMsg
            end try
            if (count of outputList) is 0 then
                return "No uncompleted reminders found."
            else
                set AppleScript's text item delimiters to "\n"
                return outputList as text
            end if
        end tell
        """
        let res = await executeAppleScript(script)
        return "### macOS Reminders (via MacUse):\n\(res)"
    }

    public func executeAppleScript(_ script: String) async -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes as data arrives rather than reading only after waitUntilExit(): besides
        // the usual deadlock once output exceeds the pipe buffer, a first-time Calendar/Reminders
        // access prompt can leave osascript blocked on a system permission dialog indefinitely, so
        // this also needs a hard timeout rather than an unbounded wait.
        let outState = ShellOutputState(maxBytes: 50_000)
        let errState = ShellOutputState(maxBytes: 50_000)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outState.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errState.append(chunk) }
        }

        let timeoutSeconds: TimeInterval = 15
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeoutTimer.schedule(deadline: .now() + timeoutSeconds)
        timeoutTimer.setEventHandler {
            if process.isRunning {
                outState.markTimedOut()
                process.terminate()
            }
        }
        timeoutTimer.resume()

        do {
            try process.run()
            process.waitUntilExit()
            timeoutTimer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let (output, didTimeOut) = outState.finalize()
            let (error, _) = errState.finalize()

            if didTimeOut {
                return "AppleScript Note: timed out after \(Int(timeoutSeconds))s — this usually means macOS is waiting on a permission prompt (System Settings → Privacy & Security → Calendars/Reminders/Automation) that needs a response."
            }
            if !output.isEmpty { return output }
            if !error.isEmpty { return "AppleScript Note: \(error)" }
            return "Script executed successfully."
        } catch {
            timeoutTimer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return "AppleScript Error: \(error.localizedDescription)"
        }
    }

    private func sendJson(_ dict: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        var payload = data
        payload.append(0x0A) // newline-delimited JSON-RPC
        // Prefer throwing write — FileHandle.write(_:) raises NSException on EPIPE and can kill the app.
        try pipe.fileHandleForWriting.write(contentsOf: payload)
    }

    public func stopServer(id: String) async {
        startGenerations[id] = (startGenerations[id] ?? 0) + 1
        if let session = sdkSessions.removeValue(forKey: id) {
            await session.stop()
        }
        if let outPipe = processOutputPipes[id] {
            outPipe.fileHandleForReading.readabilityHandler = nil
        }
        if let proc = runningProcesses[id] {
            if proc.isRunning {
                proc.terminate()
            }
            runningProcesses.removeValue(forKey: id)
        }
        processInputPipes.removeValue(forKey: id)
        processOutputPipes.removeValue(forKey: id)
        processOutputBuffers.removeValue(forKey: id)
        if serverStatus[id] != .crashed && serverStatus[id] != .unreachable {
            serverStatus[id] = .notStarted
        }
    }

    public func stopAll() async {
        let ids = Set(runningProcesses.keys).union(sdkSessions.keys)
        for id in ids {
            await stopServer(id: id)
        }
    }
}

/// Thread-safe NDJSON stdout buffer for one MCP stdio process.
public final class MCPStdioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    public func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        lock.lock()
        text += chunk
        // Cap runaway buffers (log spam / huge payloads)
        if text.count > 2_000_000 {
            text = String(text.suffix(1_000_000))
        }
        lock.unlock()
    }

    /// Pull the first complete JSON-RPC response matching `id`, removing it from the buffer.
    public func extractJSONRPCResponse(id: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let remaining = text
        var consumedUpTo = remaining.startIndex
        while let lineEnd = remaining[consumedUpTo...].firstIndex(of: "\n") {
            let line = remaining[consumedUpTo..<lineEnd]
            let next = remaining.index(after: lineEnd)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            consumedUpTo = next
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            let respId: Int? = {
                if let i = json["id"] as? Int { return i }
                if let s = json["id"] as? String { return Int(s) }
                return nil
            }()
            guard respId == id else { continue }

            // Drop everything through this line from the buffer
            text = String(remaining[next...])

            if let result = json["result"] as? [String: Any] {
                if let content = result["content"] as? [[String: Any]] {
                    let texts = content.compactMap { $0["text"] as? String }
                    if !texts.isEmpty { return texts.joined(separator: "\n") }
                }
                if let tools = result["tools"] as? [[String: Any]] {
                    let names = tools.compactMap { $0["name"] as? String }
                    if !names.isEmpty {
                        return "Available tools:\n" + names.map { "- \($0)" }.joined(separator: "\n")
                    }
                }
                if let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data(), encoding: .utf8) {
                    return jsonText
                }
            } else if let error = json["error"] as? [String: Any] {
                return "MCP Error: \(error["message"] as? String ?? "Unknown error")"
            }
            return trimmed
        }
        return nil
    }
}

// MARK: - Request Throttling Extension
public extension MCPClientManager {
    func shouldAcceptRequest() -> Bool {
        pendingRequests < maxConcurrentRequests
    }
    
    func acquireRequestSlot() -> Bool {
        if pendingRequests < maxConcurrentRequests {
            pendingRequests += 1
            return true
        }
        return false
    }
    
    func releaseRequestSlot() {
        if pendingRequests > 0 {
            pendingRequests -= 1
        }
    }
}
