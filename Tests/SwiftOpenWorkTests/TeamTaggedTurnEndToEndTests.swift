import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// The goal of the Team map, end to end: make a department with a lead, a researcher and a coder,
/// send one prompt to `@App-Coder`, and watch the three work together. This goes through the real
/// `AppState.sendMessage`, the real agent loop, the real `agent_spawn` tool and the real sub-agent
/// executor; only the model is scripted (see `ScriptedModelServer`).
@MainActor
final class TeamTaggedTurnEndToEndTests: XCTestCase {

    func testTaggingADepartmentMakesItsLeadDelegateToTheTeamAndReportOneResult() async throws {
        // Never touch a real person's data: the app must be pointed at a throwaway directory.
        XCTAssertTrue(AppIdentity.isHostedByTests)
        XCTAssertTrue(StorageService.resolvedBaseDirectory.path.lowercased().contains("test"),
                      "refusing to run against \(StorageService.resolvedBaseDirectory.path)")

        let server = ScriptedModelServer { request in
            let system = request.system
            if system.contains("lead of a software team") {
                switch request.toolResults.count {
                case 0:
                    return .tool(name: "agent_spawn", arguments: #"{"target_agent_id":"App-Coder Researcher","task_title":"Find what a todo app needs","task_description":"List the key features."}"#)
                case 1:
                    return .tool(name: "agent_spawn", arguments: #"{"target_agent_id":"App-Coder Coder","task_title":"Write the todo app","task_description":"Implement it using the research."}"#)
                default:
                    return .text("RESULT: the todo app is built. Research found list, add and delete; the coder wrote TodoApp.swift.")
                }
            }
            if system.contains("researcher on a software team") { return .text("RESEARCH-NOTES: a todo app needs list, add and delete.") }
            if system.contains("coder on a software team") { return .text("CODER-DONE: wrote TodoApp.swift.") }
            return .text("UNEXPECTED SPEAKER")
        }
        try server.start()
        defer { server.stop() }

        let provider = ModelProvider(
            id: "scripted", name: "Scripted", type: .cloud, kind: .custom, baseUrl: server.baseURL,
            models: [ModelInfo(id: "scripted", name: "scripted", providerId: "scripted")]
        )
        let app = AppState()
        app.providers = [provider]
        app.selectedProviderId = "scripted"
        app.selectedModelId = "scripted"

        let made = app.createDepartment(from: DepartmentTemplateCatalog.softwareTeam, named: "App-Coder")
        XCTAssertEqual(made.map(\.role), ["Lead", "Researcher", "Coder"])
        let brief = "Always name the file you touched. HOUSE-RULE-XYZ."
        XCTAssertEqual(app.setDepartmentInstructions("App-Coder", text: brief), .saved)
        let created = made
        defer { for a in created { app.deleteAgent(a) } }

        app.createNewSession()
        app.sendMessage(text: "@App-Coder build a todo app")

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !app.isGenerating, !server.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(app.isGenerating, "the turn did not finish")

        let seen = server.requests
        let leadCalls = seen.filter { $0.system.contains("lead of a software team") }
        let researcherCalls = seen.filter { $0.system.contains("researcher on a software team") }
        let coderCalls = seen.filter { $0.system.contains("coder on a software team") }
        XCTAssertEqual(leadCalls.count, 3, "lead: plan, then after the researcher, then after the coder")
        XCTAssertEqual(researcherCalls.count, 1, "the researcher was delegated to")
        XCTAssertEqual(coderCalls.count, 1, "the coder was delegated to")
        XCTAssertEqual(seen.count, 5, "nobody else was asked: \(seen.map { String($0.system.prefix(40)) })")

        // The tag was routed to the lead, and the lead knows its team.
        XCTAssertTrue(leadCalls[0].system.contains("App-Coder Researcher"))
        XCTAssertTrue(leadCalls[0].system.contains("App-Coder Coder"))
        XCTAssertTrue(leadCalls[0].toolNames.contains("agent_spawn"))
        XCTAssertTrue(leadCalls[0].lastUser.contains("build a todo app"))

        // The department's shared instructions reach all three prompts.
        for call in [leadCalls[0], researcherCalls[0], coderCalls[0]] {
            XCTAssertTrue(call.system.contains("HOUSE-RULE-XYZ"), "missing shared instructions")
        }

        // Each delegate's result went back to the lead, and one final result came back to the person.
        XCTAssertTrue(leadCalls[1].toolResults.joined().contains("RESEARCH-NOTES"))
        XCTAssertTrue(leadCalls[2].toolResults.joined().contains("CODER-DONE"))
        let session = try XCTUnwrap(app.currentSession)
        let reply = try XCTUnwrap(session.messages.last { $0.role == .assistant && !$0.content.isEmpty })
        XCTAssertTrue(reply.content.contains("RESULT: the todo app is built"))
        XCTAssertEqual(reply.agentId, made[0].id, "the lead answered")
        XCTAssertEqual(reply.department, "App-Coder", "the reply is filed under its department for usage")
        XCTAssertFalse(session.messages.contains { $0.isError })
    }
}
