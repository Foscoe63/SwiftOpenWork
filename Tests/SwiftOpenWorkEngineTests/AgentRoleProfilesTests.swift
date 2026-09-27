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
}
