import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

final class RadiantAgentsTests: XCTestCase {
    func testAddMissingIsIdempotentAndLeavesExistingAgentsAlone() {
        var agents = [Agent(id: "security-agent", name: "My Security", systemPrompt: "mine", isBuiltIn: true)]
        XCTAssertTrue(RadiantBuiltInAgents.addMissing(to: &agents))
        XCTAssertEqual(agents.count, RadiantBuiltInAgents.agents.count)
        XCTAssertEqual(agents[0].systemPrompt, "mine", "an agent the user already has is not overwritten")
        XCTAssertFalse(RadiantBuiltInAgents.addMissing(to: &agents), "second run changes nothing")
    }

    func testNewAgentsJoinTheLeadsTeamOnceOnly() {
        var agents = [Agent(id: "lead-assistant", name: "Lead", subAgentIds: ["coder-agent"], isBuiltIn: true, isLeadAgent: true)]
        RadiantBuiltInAgents.addMissing(to: &agents)
        let newIds = RadiantBuiltInAgents.agents.map(\.id)
        XCTAssertEqual(agents[0].subAgentIds, ["coder-agent"] + newIds)
        XCTAssertTrue(RadiantBuiltInAgents.agents.allSatisfy { $0.parentAgentId == "lead-assistant" })

        agents[0].subAgentIds.removeAll { $0 == "docs-agent" }
        RadiantBuiltInAgents.addMissing(to: &agents)
        XCTAssertFalse(agents[0].subAgentIds.contains("docs-agent"), "a member the user removed is not re-added")
    }

    func testBuiltInsHaveUniqueIdsPromptsAndRealTools() {
        let agents = RadiantBuiltInAgents.agents
        XCTAssertEqual(agents.count, 9)
        XCTAssertEqual(Set(agents.map(\.id)).count, agents.count)
        let known = Set(PersistenceManager.shared.defaultTools.map(\.id))
        for agent in agents {
            XCTAssertTrue(agent.isBuiltIn)
            XCTAssertFalse(agent.systemPrompt.isEmpty, agent.name)
            XCTAssertFalse(agent.allowedToolIds.isEmpty, agent.name)
            for tool in agent.allowedToolIds where !tool.hasPrefix("mcp_") {
                XCTAssertTrue(known.contains(tool), "\(agent.name) lists unknown tool \(tool)")
            }
        }
    }

    func testTemplateCatalogIsCompleteAndMakesFreshAgents() {
        let all = AgentTemplateCatalog.templates
        XCTAssertEqual(all.count, 142)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(AgentTemplateCatalog.categories.count, 24)
        for t in all {
            XCTAssertFalse(t.persona.isEmpty, t.name)
            XCTAssertFalse(t.blurb.isEmpty, t.name)
        }
        let a = all[0].makeAgent(temperature: 0.3, maxTokens: 1000, reasoningEffort: .low)
        let b = all[0].makeAgent()
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.isBuiltIn)
        XCTAssertEqual(a.systemPrompt, all[0].persona)
        XCTAssertEqual(a.temperature, 0.3)
        XCTAssertEqual(AgentTemplateCatalog.matching(query: "copywriter", category: nil).map(\.name), ["Copywriter"])
    }
}
