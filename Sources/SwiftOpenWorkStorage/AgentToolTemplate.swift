import Foundation
import SwiftOpenWorkCore

/// A saved snapshot of which tools (and whole MCP servers) each built-in agent gets, so the
/// role setup can be exported, kept in a repository, and reloaded later — for example after a
/// user has cleared or changed an allowlist, or on another machine.
///
/// `AgentRoleProfiles.toolsByAgentId` stays the single source of truth for the shipped template;
/// this type is the portable form of it.
public struct AgentToolTemplate: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    /// `allowedToolIds` per agent id. `mcp_<server id>` admits every tool of that server.
    public var tools: [String: [String]]
    /// `allowedSkillIds` per agent id.
    public var skills: [String: [String]]
    /// MCP server ids to switch on when the template is applied. Empty in the shipped template:
    /// filesystem, fetch, memory and git are native tools, so those servers stay off unless the
    /// user opts in (the `mcp_<server>` entries above only take effect once a server is enabled).
    public var enableMCPServers: [String]

    public init(name: String, version: Int = 1, tools: [String: [String]], skills: [String: [String]] = [:], enableMCPServers: [String] = []) {
        self.name = name
        self.version = version
        self.tools = tools
        self.skills = skills
        self.enableMCPServers = enableMCPServers
    }

    /// The role-matched template that ships with the app.
    public static var builtIn: AgentToolTemplate {
        AgentToolTemplate(name: "SwiftOpenWork role tools", tools: AgentRoleProfiles.toolsByAgentId, skills: AgentRoleProfiles.skillsByAgentId)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func load(from data: Data) throws -> AgentToolTemplate {
        try JSONDecoder().decode(AgentToolTemplate.self, from: data)
    }

    // Templates exported before skills existed have no `skills` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        tools = try c.decode([String: [String]].self, forKey: .tools)
        skills = try c.decodeIfPresent([String: [String]].self, forKey: .skills) ?? [:]
        enableMCPServers = try c.decodeIfPresent([String].self, forKey: .enableMCPServers) ?? []
    }

    /// Captures what the given agents have now (built-ins and custom agents with an allowlist).
    public static func capture(from agents: [Agent], servers: [MCPServerConfig], name: String) -> AgentToolTemplate {
        AgentToolTemplate(
            name: name,
            tools: Dictionary(uniqueKeysWithValues: agents.filter { !$0.allowedToolIds.isEmpty }.map { ($0.id, $0.allowedToolIds) }),
            skills: Dictionary(uniqueKeysWithValues: agents.compactMap { a in (a.allowedSkillIds ?? []).isEmpty ? nil : (a.id, a.allowedSkillIds ?? []) }),
            enableMCPServers: servers.filter(\.isEnabled).map(\.id)
        )
    }

    /// Sets each matching agent's allowlist to the template's and turns on the listed MCP servers.
    /// Agents the template does not mention are left alone. Returns true when anything changed.
    @discardableResult
    public func apply(to agents: inout [Agent], servers: inout [MCPServerConfig]) -> Bool {
        var changed = false
        for i in agents.indices {
            var touched = false
            if let tools = self.tools[agents[i].id], agents[i].allowedToolIds != tools {
                agents[i].allowedToolIds = tools
                touched = true
            }
            if let skills = self.skills[agents[i].id], agents[i].allowedSkillIds ?? [] != skills {
                agents[i].allowedSkillIds = skills
                touched = true
            }
            if touched {
                agents[i].updatedAt = Date()
                changed = true
            }
        }
        for i in servers.indices where enableMCPServers.contains(servers[i].id) && !servers[i].isEnabled {
            servers[i].isEnabled = true
            changed = true
        }
        return changed
    }
}
