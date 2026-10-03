import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

final class AgentRoleProfilesTests: XCTestCase {
    func testMigrationFixesSwappedNamesAndFillsEmptyAllowlists() {
        var agents = [
            Agent(id: "coder-agent", name: "Reviewer-Agent", isBuiltIn: true),
            Agent(id: "reviewer-agent", name: "Coder-Agent", isBuiltIn: true),
            Agent(id: "research-agent", name: "Reasearch-Agent", allowedToolIds: ["file_read"], isBuiltIn: true),
        ]
        XCTAssertTrue(AgentRoleProfiles.migrate(&agents))
        XCTAssertEqual(agents[0].name, "Software Engineer Agent")
        XCTAssertEqual(agents[1].name, "Code Review & Quality Critic")
        XCTAssertEqual(agents[2].name, "Deep Research Agent")
        XCTAssertTrue(agents[0].allowedToolIds.contains("edit_file"))
        XCTAssertFalse(agents[1].allowedToolIds.contains("edit_file"), "the reviewer must be read-only")
        XCTAssertEqual(agents[2].allowedToolIds, ["file_read"], "a user's own allowlist is kept")
        XCTAssertFalse(AgentRoleProfiles.migrate(&agents), "second run changes nothing")
    }

    func testAddMissingSkillsIsIdempotent() {
        var skills: [Skill] = []
        XCTAssertTrue(AgentRoleProfiles.addMissingSkills(to: &skills))
        XCTAssertEqual(skills.count, AgentRoleProfiles.extraSkills.count)
        XCTAssertFalse(AgentRoleProfiles.addMissingSkills(to: &skills))
    }

    func testEveryBuiltInAgentHasARoleProfileWithRealTools() {
        let known = Set(PersistenceManager.shared.defaultTools.map(\.id))
        let ids = PersistenceManager.shared.defaultAgents.map(\.id) + RadiantBuiltInAgents.agents.map(\.id)
        for id in ids {
            let tools = AgentRoleProfiles.toolsByAgentId[id] ?? []
            XCTAssertFalse(tools.isEmpty, "\(id) has no role profile")
            for tool in tools where !tool.hasPrefix("mcp_") {
                XCTAssertTrue(known.contains(tool), "\(id) lists unknown tool \(tool)")
            }
        }
    }

    func testToolTemplateRoundTripsAndReappliesOverEditedAgents() throws {
        let template = AgentToolTemplate.builtIn
        let reloaded = try AgentToolTemplate.load(from: template.jsonData())
        XCTAssertEqual(reloaded, template)

        var agents = [Agent(id: "comms-organizer-agent", name: "Comms", allowedToolIds: ["file_read"], isBuiltIn: true)]
        var servers = [MCPServerConfig(id: "mcp-memory", name: "Memory", command: "npx", isEnabled: false)]
        var withServer = reloaded
        withServer.enableMCPServers = ["mcp-memory"]
        XCTAssertTrue(withServer.apply(to: &agents, servers: &servers))
        XCTAssertEqual(agents[0].allowedToolIds, AgentRoleProfiles.toolsByAgentId["comms-organizer-agent"])
        XCTAssertTrue(servers[0].isEnabled)
        XCTAssertFalse(withServer.apply(to: &agents, servers: &servers), "second apply changes nothing")
    }

    func testEveryAgentHasItsOwnToolsAndSkills() {
        let ids = PersistenceManager.shared.defaultAgents.map(\.id) + RadiantBuiltInAgents.agents.map(\.id)
        let known = Set(PersistenceManager.shared.loadSkills().map(\.id))
        var toolSets = Set<[String]>(), skillSets = Set<[String]>()
        for id in ids where id != "lead-assistant" {
            let skills = AgentRoleProfiles.skillsByAgentId[id] ?? []
            XCTAssertFalse(skills.isEmpty, "\(id) has no skill profile")
            for skill in skills where !skill.hasPrefix("project:") {
                XCTAssertTrue(known.contains(skill), "\(id) lists unknown skill \(skill)")
            }
            XCTAssertTrue(toolSets.insert(AgentRoleProfiles.toolsByAgentId[id] ?? []).inserted, "\(id) shares its tool list")
            XCTAssertTrue(skillSets.insert(skills).inserted, "\(id) shares its skill list")
        }
    }

    func testSkillAllowlistFiltersAndEmptyMeansAll() {
        let builtIn = Skill(id: "a-skill", name: "A")
        let project = Skill(id: "project:design-ui-designer/SKILL.md", name: "agency-ui-designer", source: .project)
        XCTAssertTrue(builtIn.isAllowed(by: nil))
        XCTAssertTrue(builtIn.isAllowed(by: []))
        XCTAssertFalse(builtIn.isAllowed(by: ["other"]))
        XCTAssertTrue(project.isAllowed(by: ["project:design-ui-designer"]))
        XCTAssertFalse(project.isAllowed(by: ["project:design-ux-architect"]))
    }

    // MARK: - Hindsight

    private let dangerousHindsight = ["clear_memories", "delete_bank", "delete_document", "update_bank", "sync_retain"]

    /// Every agent reads and writes Hindsight memory, and none holds the whole server, whose
    /// `clear_memories` and `delete_bank` would wipe the store.
    func testEveryProfileHasHindsightRecallAndRetainButNeverTheWholeServer() {
        for (id, tools) in AgentRoleProfiles.toolsByAgentId {
            XCTAssertTrue(tools.contains("mcp__mcp-hindsight__recall"), "\(id) cannot recall")
            XCTAssertTrue(tools.contains("mcp__mcp-hindsight__retain"), "\(id) cannot retain")
            XCTAssertFalse(tools.contains("mcp_mcp-hindsight"), "\(id) holds the whole Hindsight server")
            for name in dangerousHindsight {
                XCTAssertFalse(tools.contains("mcp__mcp-hindsight__\(name)"), "\(id) can \(name)")
            }
            XCTAssertFalse(tools.contains("memory_store") || tools.contains("memory_recall") || tools.contains("mcp_mcp-memory"),
                           "\(id) still lists a retired memory tool")
        }
    }

    func testOnlyTheReasoningAgentsGetReflect() {
        let reflect = "mcp__mcp-hindsight__reflect"
        for (id, tools) in AgentRoleProfiles.toolsByAgentId {
            XCTAssertEqual(tools.contains(reflect), AgentRoleProfiles.reflectingAgentIds.contains(id), id)
        }
        XCTAssertTrue(AgentRoleProfiles.toolsByAgentId["research-agent"]?.contains(reflect) == true)
        XCTAssertFalse(AgentRoleProfiles.toolsByAgentId["coder-agent"]?.contains(reflect) == true)
    }

    func testHindsightMigrationSwapsMemoryToolsOnceAndLeavesOtherChoicesAlone() {
        var agents = [
            Agent(id: "reviewer-agent", name: "R", allowedToolIds: ["file_read", "memory_store", "memory_recall", "mcp_mcp-memory"], isBuiltIn: true),
            Agent(id: "mine", name: "Mine", allowedToolIds: ["file_read", "terminal_command"]),
            Agent(id: "open", name: "Open", allowedToolIds: []),
        ]
        XCTAssertTrue(AgentRoleProfiles.migrateToHindsight(&agents))
        XCTAssertEqual(agents[0].allowedToolIds, ["file_read", "mcp__mcp-hindsight__recall", "mcp__mcp-hindsight__retain"])
        XCTAssertEqual(agents[1].allowedToolIds, ["file_read", "terminal_command", "mcp__mcp-hindsight__recall", "mcp__mcp-hindsight__retain"])
        XCTAssertTrue(agents[2].allowedToolIds.isEmpty, "an empty allowlist already means everything")
        XCTAssertFalse(AgentRoleProfiles.migrateToHindsight(&agents), "second run changes nothing")
    }

    /// The point of the namespaced entries: a sub-agent sees `recall` and `retain` and not the
    /// server's destructive tools, even though all of them are advertised.
    @MainActor
    func testASubAgentSeesOnlyItsHindsightTools() {
        func mcp(_ name: String) -> Tool {
            let full = "mcp__mcp-hindsight__\(name)"
            return Tool(id: full, name: full, displayName: name, description: "", category: .mcp, parametersJsonSchema: "{}")
        }
        let all = ["recall", "retain", "reflect", "clear_memories", "delete_bank"].map(mcp)
        var settings = AppSettings.default
        settings.mcpServers = [MCPServerConfig(id: "mcp-hindsight", name: "Hindsight Memory", command: "", url: "http://127.0.0.1:8888/mcp/shared")]
        let coder = Agent(id: "coder-agent", name: "C", allowedToolIds: AgentRoleProfiles.toolsByAgentId["coder-agent"] ?? [], isBuiltIn: true)
        let names = Set(SubAgentExecutor.toolSet(for: coder, depth: 1, settings: settings, all: all).map(\.name))
        XCTAssertEqual(names, ["mcp__mcp-hindsight__recall", "mcp__mcp-hindsight__retain"])
    }

    // MARK: - New agents

    func testANewAgentGetsALeastPrivilegeBaselineButKeepsItsOwnChoices() {
        var fresh = Agent(name: "New")
        AgentRoleProfiles.applyNewAgentBaseline(to: &fresh)
        XCTAssertEqual(fresh.allowedToolIds, AgentRoleProfiles.newAgentTools)
        XCTAssertEqual(fresh.allowedSkillIds, AgentRoleProfiles.newAgentSkills)
        for risky in ["file_write", "edit_file", "terminal_command", "git_commit", "file_delete", "agent_spawn", "send_input"] {
            XCTAssertFalse(fresh.allowedToolIds.contains(risky), "baseline allows \(risky)")
        }
        XCTAssertTrue(fresh.allowedToolIds.contains("mcp__mcp-hindsight__recall"))
        XCTAssertTrue(fresh.allowedToolIds.contains("mcp__mcp-hindsight__retain"))

        var chosen = Agent(name: "Chosen", allowedToolIds: ["grep"], allowedSkillIds: ["teaching-skill"])
        AgentRoleProfiles.applyNewAgentBaseline(to: &chosen)
        XCTAssertEqual(chosen.allowedToolIds, ["grep"])
        XCTAssertEqual(chosen.allowedSkillIds, ["teaching-skill"])
    }

    func testTheBaselineNamesOnlyRealToolsAndSkills() {
        let known = Set(PersistenceManager.shared.defaultTools.map(\.id))
        for tool in AgentRoleProfiles.newAgentTools where !tool.hasPrefix("mcp_") {
            XCTAssertTrue(known.contains(tool), "baseline lists unknown tool \(tool)")
        }
        let skills = Set(AgentRoleProfiles.extraSkills.map(\.id))
        for skill in AgentRoleProfiles.newAgentSkills {
            XCTAssertTrue(skills.contains(skill), "baseline lists unknown skill \(skill)")
        }
    }
}
