import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

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
}
