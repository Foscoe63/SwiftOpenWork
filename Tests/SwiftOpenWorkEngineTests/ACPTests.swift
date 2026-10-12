import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

final class ACPMappingTests: XCTestCase {
    func testStatusAndOptionSelection() {
        XCTAssertEqual(ACPMapping.status("completed"), .success)
        XCTAssertEqual(ACPMapping.status("failed"), .error)
        XCTAssertEqual(ACPMapping.status("in_progress"), .running)
        XCTAssertEqual(ACPMapping.status(nil), .running)
        let options: [[String: Any]] = [["optionId": "a", "kind": "allow_always"], ["optionId": "b", "kind": "reject_once"], ["optionId": "c", "kind": "allow_once"]]
        XCTAssertEqual(ACPMapping.optionId(for: true, in: options), "c", "a yes is allow-once, not allow-always")
        XCTAssertEqual(ACPMapping.optionId(for: false, in: options), "b")
        XCTAssertNil(ACPMapping.optionId(for: false, in: [["optionId": "a", "kind": "allow_once"]]))
    }

    func testExternalToolCallsAreJudgedAsOurEquivalents() throws {
        let run = try XCTUnwrap(ACPMapping.equivalentTool(kind: "execute", rawInput: ["command": "git push"], locations: []))
        XCTAssertEqual(run.tool, "terminal_command")
        XCTAssertEqual(run.arguments["command"] as? String, "git push")
        let edit = try XCTUnwrap(ACPMapping.equivalentTool(kind: "edit", rawInput: [:], locations: ["/p/a.swift"]))
        XCTAssertEqual(edit.tool, "file_write")
        XCTAssertNil(ACPMapping.equivalentTool(kind: "think", rawInput: [:], locations: []))
    }

    func testPresetsAreComplete() {
        XCTAssertGreaterThanOrEqual(ACPMapping.presets.count, 4)
        XCTAssertTrue(ACPMapping.presets.allSatisfy { !$0.config.command.isEmpty })
    }

    func testAgentsSavedBeforeExternalAgentsExistStillDecode() throws {
        let old = ##"{"id":"a","name":"Old","description":"","avatar":"x","color":"#fff","role":"r","systemPrompt":"p","providerId":"","modelId":"","temperature":0.7,"maxTokens":100,"topP":1,"reasoningEffort":"low","subAgentIds":[],"allowedToolIds":[],"canSpawnSubAgents":true,"maxSubAgentDepth":3,"autoDelegate":true,"canCommunicateWithOthers":true,"tags":[],"isBuiltIn":false,"isLeadAgent":false,"createdAt":0,"updatedAt":0}"##
        let agent = try JSONDecoder().decode(Agent.self, from: Data(old.utf8))
        XCTAssertNil(agent.externalAgent)
        let external = Agent(name: "X", externalAgent: ExternalAgentConfig(command: "gemini", args: ["--experimental-acp"]))
        let round = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(external))
        XCTAssertEqual(round.externalAgent?.displayLine, "gemini --experimental-acp")
    }
}

/// A real ACP conversation with a scripted agent process (`fake_acp_agent.py`).
@MainActor
final class ACPRunnerTests: XCTestCase {
    private var root = ""
    private var fake = ""
    private var originalSettings: AppSettings?

    override func setUpWithError() throws {
        originalSettings = PersistenceManager.shared.loadSettings()
        root = ToolExecutionEngine.canonicalPath(NSTemporaryDirectory()) + "/acp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_acp_agent.py").path
        PermissionRules.globalPathOverride = root + "/none.json"
        ToolHooks.globalPathOverride = root + "/none-hooks.json"
        var settings = PersistenceManager.shared.loadSettings()
        settings.terminalSafetyLevel = .alwaysAsk
        PersistenceManager.shared.saveSettings(settings)
        try "top secret".write(toFile: root + "/secret.txt", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let originalSettings { PersistenceManager.shared.saveSettings(originalSettings) }
        PermissionRules.globalPathOverride = nil
        ToolHooks.globalPathOverride = nil
        try? FileManager.default.removeItem(atPath: root)
    }

    private final class Sink: @unchecked Sendable {
        var latest: ChatMessage?
        var todos: [SessionTodoItem] = []
    }

    private func turn(_ text: String, agentId: String = "ext", sink: Sink, approve: Bool? = nil) async -> ChatMessage? {
        var session = Session(agentId: agentId)
        session.id = "acp-session-\(agentId)"
        session.messages.append(ChatMessage(sessionId: session.id, role: .user, content: text))
        let agent = Agent(id: agentId, name: "Fake", externalAgent: ExternalAgentConfig(command: "python3", args: [fake, root]))
        let workspace = Workspace(name: "T", folderPath: root)
        if let approve {
            // Answer the approval card the way the UI would.
            Task { @MainActor in
                for _ in 0..<200 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let pending = ToolApprovalManager.shared.pendingApprovals.first {
                        ToolApprovalManager.shared.resolve(callId: pending.id, approved: approve)
                        return
                    }
                }
            }
        }
        await ACPAgentRunner.run(
            session: session, agent: agent, config: agent.externalAgent!, workspace: workspace,
            onMessageUpdated: { sink.latest = $0 }, onSessionTodosUpdated: { sink.todos = $0 }
        )
        await ACPSessionPool.shared.stopAll()
        return sink.latest
    }

    func testAPlainTurnStreamsTextReasoningAndPlan() async throws {
        let sink = Sink()
        let message = try await XCTUnwrapAsync(await turn("hello", sink: sink))
        XCTAssertEqual(message.content, "Hello from the fake agent")
        XCTAssertFalse(message.isStreaming)
        XCTAssertEqual(message.reasoning, "thinking")
        XCTAssertEqual(sink.todos.first?.content, "step one")
        XCTAssertEqual(sink.todos.first?.status, .inProgress)
        XCTAssertNil(message.haltReason)
    }

    func testApprovedWriteGoesThroughOurFileToolsAndShowsADiff() async throws {
        let sink = Sink()
        let message = try await XCTUnwrapAsync(await turn("please write notes", sink: sink, approve: true))
        XCTAssertEqual(try String(contentsOfFile: root + "/notes.txt", encoding: .utf8), "hello from acp\n")
        XCTAssertEqual(message.content, "wrote it")
        let call = try XCTUnwrap(message.toolCalls.first)
        XCTAssertEqual(call.status, .success)
        XCTAssertEqual(call.fileDiffs?.first?.path, root + "/notes.txt")
    }

    func testRejectedWriteIsNotPerformed() async throws {
        let sink = Sink()
        let message = try await XCTUnwrapAsync(await turn("please write notes", agentId: "ext2", sink: sink, approve: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/notes.txt"))
        XCTAssertEqual(message.content, "not allowed")
        XCTAssertEqual(message.toolCalls.first?.status, .error)
    }

    func testADenyRuleAnswersWithoutAskingAnyone() async throws {
        try FileManager.default.createDirectory(atPath: root + "/.swiftopenwork", withIntermediateDirectories: true)
        try Data(#"{"deny":["file_write(notes.txt)"]}"#.utf8).write(to: URL(fileURLWithPath: root + "/.swiftopenwork/permissions.json"))
        let sink = Sink()
        let message = try await XCTUnwrapAsync(await turn("please write notes", agentId: "ext3", sink: sink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/notes.txt"))
        XCTAssertEqual(message.content, "not allowed")
        XCTAssertTrue(ToolApprovalManager.shared.pendingApprovals.isEmpty)
    }

    func testReadsOfSecretsAndOutsideTheWorkspaceAreRefused() async throws {
        // The workspace file is readable...
        let sink = Sink()
        let readable = try await XCTUnwrapAsync(await turn("read it", agentId: "ext4", sink: sink))
        XCTAssertEqual(readable.content, "read: top secret")
        // ...and a path outside is not (the fake reads <root>/secret.txt, so point it elsewhere).
        let outside = ToolExecutionEngine.canonicalPath(NSTemporaryDirectory()) + "/acp-outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try "nope".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
        var session = Session(agentId: "ext5"); session.id = "acp-out"
        session.messages.append(ChatMessage(sessionId: session.id, role: .user, content: "read it"))
        let agent = Agent(id: "ext5", name: "Fake", externalAgent: ExternalAgentConfig(command: "python3", args: [fake, outside]))
        let sink2 = Sink()
        await ACPAgentRunner.run(session: session, agent: agent, config: agent.externalAgent!, workspace: Workspace(name: "T", folderPath: root),
                                 onMessageUpdated: { sink2.latest = $0 }, onSessionTodosUpdated: nil)
        await ACPSessionPool.shared.stopAll()
        XCTAssertTrue(sink2.latest?.content.contains("ERROR") == true, sink2.latest?.content ?? "")
        XCTAssertFalse(sink2.latest?.content.contains("nope") == true)
    }

    func testAMissingProgramIsReportedNotHung() async throws {
        var session = Session(agentId: "ghost"); session.id = "acp-ghost"
        session.messages.append(ChatMessage(sessionId: session.id, role: .user, content: "hi"))
        let agent = Agent(id: "ghost", name: "Ghost", externalAgent: ExternalAgentConfig(command: "definitely-not-installed-acp", args: []))
        let sink = Sink()
        await ACPAgentRunner.run(session: session, agent: agent, config: agent.externalAgent!, workspace: Workspace(name: "T", folderPath: root),
                                 onMessageUpdated: { sink.latest = $0 }, onSessionTodosUpdated: nil)
        XCTAssertEqual(sink.latest?.haltReason, "agent_unavailable")
        XCTAssertFalse(sink.latest?.isStreaming ?? true)
    }

    func testStopCancelsTheAgentAndKeepsWhatItSaid() async throws {
        var session = Session(agentId: "slow"); session.id = "acp-slow"
        session.messages.append(ChatMessage(sessionId: session.id, role: .user, content: "hang"))
        let agent = Agent(id: "slow", name: "Slow", externalAgent: ExternalAgentConfig(command: "python3", args: [fake, root]))
        let sink = Sink()
        let run = Task { @MainActor in
            await ACPAgentRunner.run(session: session, agent: agent, config: agent.externalAgent!, workspace: Workspace(name: "T", folderPath: root),
                                     onMessageUpdated: { sink.latest = $0 }, onSessionTodosUpdated: nil)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(sink.latest?.content, "working...")
        run.cancel()
        await run.value
        XCTAssertEqual(sink.latest?.haltReason, "stopped")
        XCTAssertEqual(sink.latest?.content.contains("working..."), true)
        await ACPSessionPool.shared.stopAll()
    }

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let resolved = try await value()
        return try XCTUnwrap(resolved, file: file, line: line)
    }
}
