import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Two guarantees of the agent loop, through the real `AppState.sendMessage` with a scripted model:
/// a Stop hook that fails sends the agent back to fix it before it may finish, and an agent that
/// announces an action but calls no tool late in a long turn is still nudged.
@MainActor
final class StopHookAndStallTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "stophook-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ToolHooks.globalPathOverride = nil
        try? FileManager.default.removeItem(atPath: root)
    }

    private func makeApp(_ server: ScriptedModelServer) -> AppState {
        XCTAssertTrue(AppIdentity.isHostedByTests)
        XCTAssertTrue(StorageService.resolvedBaseDirectory.path.lowercased().contains("test"))
        let provider = ModelProvider(
            id: "scripted", name: "Scripted", type: .cloud, kind: .custom, baseUrl: server.baseURL,
            models: [ModelInfo(id: "scripted", name: "scripted", providerId: "scripted")]
        )
        let app = AppState()
        app.providers = [provider]
        app.selectedProviderId = "scripted"
        app.selectedModelId = "scripted"
        return app
    }

    private func finish(_ app: AppState, _ server: ScriptedModelServer) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !app.isGenerating, !server.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(app.isGenerating, "the turn did not finish")
    }

    func testAFailingStopHookSendsTheAgentBackAndThePassingOneLetsItFinish() async throws {
        // Fails the first time it runs, passes after: "the checker found a problem, the agent fixed it".
        let counter = root + "/ran-once"
        let hooks = root + "/hooks.json"
        let command = "[ -f \(counter) ] && exit 0; touch \(counter); echo 'ERROR map: 2 calls missing' >&2; exit 2"
        let json: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: hooks))
        ToolHooks.globalPathOverride = hooks

        let server = ScriptedModelServer { request in
            request.lastUser.contains("ERROR map: 2 calls missing") ? .text("FIXED. Final answer.") : .text("All done.")
        }
        try server.start()
        defer { server.stop() }
        let app = makeApp(server)
        app.createNewSession()
        app.sendMessage(text: "do the thing")
        try await finish(app, server)

        let seen = server.requests
        XCTAssertEqual(seen.count, 2, "one answer, one retry after the hook refused: \(seen.map(\.lastUser))")
        XCTAssertTrue(seen.last?.lastUser.contains("[System Command]") == true)
        XCTAssertTrue(seen.last?.lastUser.contains("ERROR map: 2 calls missing") == true, "the checker's reason reaches the agent")
        let session = try XCTUnwrap(app.currentSession)
        let reply = try XCTUnwrap(session.messages.last { $0.role == .assistant && !$0.content.isEmpty })
        XCTAssertTrue(reply.content.contains("FIXED. Final answer."))
        XCTAssertFalse(session.messages.contains { $0.role == .user && $0.content.hasPrefix("[System Command]") }, "the nudge is not saved into the chat")
    }

    func testAHookThatNeverPassesIsOverruledAfterThreeRefusals() async throws {
        let hooks = root + "/hooks.json"
        let json: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo 'still failing' >&2; exit 2"]]]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: hooks))
        ToolHooks.globalPathOverride = hooks

        let server = ScriptedModelServer { _ in .text("Done, honestly.") }
        try server.start()
        defer { server.stop() }
        let app = makeApp(server)
        app.createNewSession()
        app.sendMessage(text: "do the thing")
        try await finish(app, server)

        XCTAssertEqual(server.requests.count, 4, "the first answer plus three sends back, then the turn ends")
    }

    func testALateAnnouncedActionWithNoToolCallIsStillNudged() async throws {
        let server = ScriptedModelServer { request in
            if request.lastUser.contains("did not call a tool") { return .text("\n\nEverything is complete.") }
            if request.toolResults.count < 7 { return .tool(name: "file_list", arguments: "{\"path\":\".\",\"limit\":\(100 + request.toolResults.count)}") }
            return .text("Found it. Now let me check the config file.")
        }
        try server.start()
        defer { server.stop() }
        let app = makeApp(server)
        app.createNewSession()
        app.sendMessage(text: "look around")
        try await finish(app, server)

        let nudged = server.requests.filter { $0.lastUser.contains("did not call a tool") }
        XCTAssertEqual(nudged.count, 1, "step 8 announced an action without calling a tool and was nudged: \(server.requests.map { "\($0.toolResults.count)|" + String($0.lastUser.prefix(50)) })")
        let reply = try XCTUnwrap(app.currentSession?.messages.last { $0.role == .assistant && !$0.content.isEmpty })
        XCTAssertTrue(reply.content.contains("Everything is complete."))
    }
}
