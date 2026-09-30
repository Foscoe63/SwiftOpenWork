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
