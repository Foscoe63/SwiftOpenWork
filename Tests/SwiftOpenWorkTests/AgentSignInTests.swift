import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

final class AgentSignInTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "AgentSignInTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testClaudeStatusParsing() {
        XCTAssertEqual(AgentSignIn.parseClaudeStatus(#"{"loggedIn": true, "email": "a@b.c"}"#), .signedIn("a@b.c"))
        XCTAssertEqual(AgentSignIn.parseClaudeStatus(#"{"loggedIn": false}"#), .signedOut)
        if case .unknown = AgentSignIn.parseClaudeStatus("command not found") {} else { XCTFail("garbage must be unknown") }
    }

    func testOpenCodeStatusParsing() {
        XCTAssertEqual(AgentSignIn.parseOpenCodeList("0 credentials"), .signedOut)
        XCTAssertEqual(AgentSignIn.parseOpenCodeList("●  Anthropic oauth\n●  OpenAI api"), .signedIn("2 providers"))
    }

    func testSeedingAddsEachProfileOnceAndRespectsRemoval() {
        let defaults = freshDefaults()
        var agents: [Agent] = []
        XCTAssertTrue(AgentSignInProfile.seedMissing(into: &agents, defaults: defaults))
        XCTAssertEqual(agents.count, AgentSignInProfile.all.count)

        // Removed by the person: not brought back on the next launch.
        agents.removeAll()
        XCTAssertFalse(AgentSignInProfile.seedMissing(into: &agents, defaults: defaults))
        XCTAssertTrue(agents.isEmpty)
    }

    func testSeedingSkipsAnAgentAlreadyOnTheSameLogin() {
        let desktop = AgentSignInProfile.all.first { $0.id == "builtin-claude-desktop" }!
        var existing = Agent(name: "Claude Code (second account)", externalAgent: desktop.config)
        existing.canSpawnSubAgents = false
        var agents = [existing]
        AgentSignInProfile.seedMissing(into: &agents, defaults: freshDefaults())
        XCTAssertEqual(agents.filter { $0.externalAgent?.env["CLAUDE_CONFIG_DIR"] == desktop.configDir }.count, 1)
    }

    func testShellQuotingSurvivesApostrophes() {
        XCTAssertEqual(AgentSignIn.quote("it's"), "'it'\\''s'")
    }
}
