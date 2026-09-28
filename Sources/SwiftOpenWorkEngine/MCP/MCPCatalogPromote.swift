import Foundation
import SwiftOpenWorkCore

/// A catalog tool discovered at runtime behind a meta-tool, promoted to a directly callable tool.
public struct MCPPromotedTool: Sendable, Hashable, Identifiable {
    public var id: String { chatName }
    /// Name the model sees and calls: `mcp__<serverId>__<nested>`.
    public var chatName: String
    public var serverId: String
    public var serverName: String
    /// The meta-tool that actually dispatches this call (e.g. `call_tool_by_name`).
    public var executeTool: String
    /// The nested catalog name to inject as `arguments.name`.
    public var injectName: String
    public var toolDescription: String
    public var inputSchemaJson: String

    public init(
        chatName: String,
        serverId: String,
        serverName: String,
        executeTool: String,
        injectName: String,
        toolDescription: String = "",
        inputSchemaJson: String = #"{"type":"object","properties":{}}"#
    ) {
        self.chatName = chatName
        self.serverId = serverId
        self.serverName = serverName
        self.executeTool = executeTool
        self.injectName = injectName
        self.toolDescription = toolDescription
        self.inputSchemaJson = inputSchemaJson
    }
}

/// Turns meta-tool catalogs into first-class tools mid-turn.
///
/// Servers like MacUse advertise only `get_tool_definitions` / `call_tool_by_name`; the tools that
/// do the work are behind them. Without promotion the model has to nest every call by hand, which
/// local models get wrong constantly. After a catalog comes back, its entries are added to the
/// live tool list with real schemas so the next step is a direct one-hop call.
public enum MCPCatalogPromote: Sendable {
    public static let maxPromoted = 64

    /// Meta-tools are the dispatchers themselves — promoting them would just re-create the wrapper.
    public static func isDispatcher(_ name: String) -> Bool {
        let leaf = (MCPNamespacedTool.parse(name)?.toolName ?? name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return leaf == "call_tool_by_name"
            || leaf == "call_tool"
            || leaf == "get_tool_definitions"
            || leaf == "list_tools"
            || leaf == "tools_list"
            || leaf.hasSuffix("_search_tools")
            || leaf.hasSuffix("_call_tool")
    }

    /// True when `toolName` is a meta-tool whose *result* is a catalog worth harvesting.
    public static func isCatalogSource(_ toolName: String) -> Bool {
        let leaf = (MCPNamespacedTool.parse(toolName)?.toolName ?? toolName).lowercased()
        return leaf.contains("get_tool_definitions")
            || leaf.contains("list_tools")
            || leaf.contains("search_tools")
    }

    // MARK: - Harvest

    /// Pull tool definitions out of a meta-tool result.
    ///
    /// Tolerant by design: servers return the catalog as a bare array, under `tools`/`definitions`/
    /// `results`, or as prose with backticked names. Anything with a usable `name` is taken.
    public static func harvest(
        server: MCPServerConfig,
        executeTool: String,
        resultText: String
    ) -> [MCPPromotedTool] {
        var found = harvestJSON(server: server, executeTool: executeTool, text: resultText)
        if found.isEmpty {
            found = harvestBacktickNames(server: server, executeTool: executeTool, text: resultText)
        }
        return Array(found.prefix(maxPromoted))
    }

    private static func harvestJSON(
        server: MCPServerConfig,
        executeTool: String,
        text: String
    ) -> [MCPPromotedTool] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        let entries = toolArrays(in: root)
        var seen = Set<String>()
        var out: [MCPPromotedTool] = []
        for entry in entries {
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  !isDispatcher(name),
                  seen.insert(name).inserted else { continue }

            let schemaObj = entry["inputSchema"] as? [String: Any]
                ?? entry["input_schema"] as? [String: Any]
                ?? entry["parameters"] as? [String: Any]
            var schemaJson = #"{"type":"object","properties":{}}"#
            if let schemaObj,
               JSONSerialization.isValidJSONObject(schemaObj),
               let encoded = try? JSONSerialization.data(withJSONObject: schemaObj),
               let s = String(data: encoded, encoding: .utf8) {
                schemaJson = s
            }
            out.append(
                MCPPromotedTool(
                    chatName: MCPNamespacedTool.name(serverId: server.id, toolName: name),
                    serverId: server.id,
                    serverName: server.name,
                    executeTool: executeTool,
                    injectName: name,
                    toolDescription: (entry["description"] as? String) ?? "",
                    inputSchemaJson: schemaJson
                )
            )
        }
        return out
    }

    /// The catalog array in a meta-tool payload.
    ///
    /// Servers nest it differently — bare at the top level, under `tools`, or under something
    /// like `data.tools` — and a payload often contains *several* arrays of name-bearing objects
    /// (MacUse ships an `actions` array of example calls alongside the real catalog). Picking the
    /// first one found made the result depend on dictionary ordering, which is not stable: the
    /// same payload could promote the catalog on one run and four examples on the next.
    ///
    /// So collect every candidate and keep the richest — the catalog is the array with the most
    /// distinct tool names, and ties break toward the one carrying schemas.
    private static func toolArrays(in value: Any, depth: Int = 0) -> [[String: Any]] {
        let candidates = collectCandidates(in: value, depth: depth)
        guard !candidates.isEmpty else { return [] }
        return candidates.max { a, b in
            let aNames = Set(a.compactMap { $0["name"] as? String }).count
            let bNames = Set(b.compactMap { $0["name"] as? String }).count
            if aNames != bNames { return aNames < bNames }
            return schemaCount(a) < schemaCount(b)
        } ?? []
    }

    private static func schemaCount(_ objects: [[String: Any]]) -> Int {
        objects.filter {
            $0["inputSchema"] != nil || $0["input_schema"] != nil || $0["parameters"] != nil
        }.count
    }

    private static func collectCandidates(in value: Any, depth: Int) -> [[[String: Any]]] {
        guard depth < 8 else { return [] }
        if let array = value as? [Any] {
            var out: [[[String: Any]]] = []
            let objects = array.compactMap { $0 as? [String: Any] }
            if !objects.isEmpty, objects.contains(where: { $0["name"] is String }) {
                out.append(objects)
            }
            // Keep descending: a wrapper array can still contain the real catalog.
            for element in array {
                out.append(contentsOf: collectCandidates(in: element, depth: depth + 1))
            }
            return out
        }
        if let dict = value as? [String: Any] {
            var out: [[[String: Any]]] = []
            for (_, nested) in dict {
                out.append(contentsOf: collectCandidates(in: nested, depth: depth + 1))
            }
            return out
        }
        return []
    }

    private static func harvestBacktickNames(
        server: MCPServerConfig,
        executeTool: String,
        text: String
    ) -> [MCPPromotedTool] {
        let pattern = "`([a-zA-Z][a-zA-Z0-9_.-]{2,63})`"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var out: [MCPPromotedTool] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            // Backtick prose is noisy — require a name that looks like a tool identifier.
            guard name.contains("_"), !isDispatcher(name), seen.insert(name).inserted else { continue }
            out.append(
                MCPPromotedTool(
                    chatName: MCPNamespacedTool.name(serverId: server.id, toolName: name),
                    serverId: server.id,
                    serverName: server.name,
                    executeTool: executeTool,
                    injectName: name,
                    toolDescription: "Catalog tool on \(server.name)."
                )
            )
        }
        return out
    }

    // MARK: - Presentation & execution

    public static func toolModel(for promoted: MCPPromotedTool, effect: MCPEffect) -> Tool {
        let base = promoted.toolDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = base.isEmpty
            ? "[\(promoted.serverName)] \(promoted.injectName). Pass this tool's arguments directly."
            : "[\(promoted.serverName)] \(base)"
        return Tool(
            id: promoted.chatName,
            name: promoted.chatName,
            displayName: "\(promoted.serverName): \(promoted.injectName)",
            description: String(description.prefix(400)),
            category: .mcp,
            parametersJsonSchema: MCPSchemaShape.normalized(promoted.inputSchemaJson),
            isEnabled: true,
            requiresApproval: effect == .write
        )
    }

    /// Rewrite a direct call to a promoted tool back into the meta-tool shape the server expects.
    public static func dispatchArguments(
        for promoted: MCPPromotedTool,
        raw: [String: Any]
    ) -> [String: Any] {
        // A schema that declares nothing (the placeholder given to tools found only by name) says
        // nothing about which parameters are structured, so it does not switch repair off.
        let schema = MCPArgSchema(json: promoted.inputSchemaJson).flatMap { $0.isEmpty ? nil : $0 }
        // The model passes the catalog tool's own fields; nest them under `arguments`.
        var inner = raw
        // A stray `name` is the model restating which tool it means — unless the tool has a
        // parameter of that name, in which case it is data and must reach the tool.
        if schema?.declares("name") != true {
            inner.removeValue(forKey: "name")
        }
        if let nested = raw["arguments"] as? [String: Any], schema?.declares("arguments") != true {
            inner = nested
        }
        return [
            "name": promoted.injectName,
            "arguments": MCPToolArgumentDefaults.coerceJSONMaps(in: inner, schema: schema),
        ]
    }
}

/// Registry of promoted tools, so the execution engine can resolve a direct call to the meta-tool
/// that dispatches it.
///
/// Each run registers under its own owner and clears only what it registered. It used to be one
/// shared map wiped at the start of every run, so a chat turn begun while a Loop was mid-turn
/// erased the Loop's promoted tools and its next call failed as unknown.
public actor MCPPromotedToolRegistry {
    public static let shared = MCPPromotedToolRegistry()

    private var promoted: [String: MCPPromotedTool] = [:]
    private var owners: [String: Set<String>] = [:]

    private init() {}

    /// Store newly harvested tools. Returns only the ones this owner has not registered before,
    /// so the caller can announce them once.
    @discardableResult
    public func register(_ tools: [MCPPromotedTool], owner: String = "") -> [MCPPromotedTool] {
        var newcomers: [MCPPromotedTool] = []
        for tool in tools where !(owners[tool.chatName]?.contains(owner) ?? false) {
            guard promoted.count < MCPCatalogPromote.maxPromoted || promoted[tool.chatName] != nil else { break }
            promoted[tool.chatName] = tool
            owners[tool.chatName, default: []].insert(owner)
            newcomers.append(tool)
        }
        return newcomers
    }

    public func lookup(_ chatName: String) -> MCPPromotedTool? {
        promoted[chatName]
    }

    /// What `owner` registered (everything, for the default owner used by tests and old callers).
    public func all(owner: String? = nil) -> [MCPPromotedTool] {
        promoted.values
            .filter { owner == nil || owners[$0.chatName]?.contains(owner!) == true }
            .sorted { $0.chatName < $1.chatName }
    }

    /// Forget what `owner` registered; a tool another run also registered stays for that run.
    public func reset(owner: String = "") {
        for name in Array(owners.keys) {
            owners[name]?.remove(owner)
            if owners[name]?.isEmpty ?? true {
                owners.removeValue(forKey: name)
                promoted.removeValue(forKey: name)
            }
        }
    }
}
