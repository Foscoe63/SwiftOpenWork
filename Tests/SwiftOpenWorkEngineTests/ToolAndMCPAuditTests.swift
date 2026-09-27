import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Regressions from an audit of tool calling, MCP and the agent loop. Each test names the failure
/// it stops from coming back.
@MainActor
final class ToolAndMCPAuditTests: XCTestCase {

    private func server(_ name: String) -> MCPServerConfig {
        MCPServerConfig(id: "srv-\(name)", name: name, command: "npx")
    }

    // MARK: - MCP argument handling

    /// `create_repository{name}` was called as a tool named after the repository.
    func testAToolsOwnNameParameterIsNotTheToolName() {
        let schema = MCPArgSchema(json: #"{"type":"object","properties":{"name":{"type":"string"},"private":{"type":"boolean"}}}"#)
        let resolved = MCPClientManager.resolveMCPCall(
            toolName: "create_repository", arguments: ["name": "MyRepo", "private": true], schema: schema
        )
        XCTAssertEqual(resolved.name, "create_repository")
        XCTAssertEqual(resolved.arguments["name"] as? String, "MyRepo")
        XCTAssertEqual(resolved.arguments["private"] as? Bool, true)
    }

    func testAToolThatDeclaresParametersKeepsItsSiblings() {
        let schema = MCPArgSchema(json: #"{"type":"object","properties":{"query":{"type":"string"},"parameters":{"type":"object"}}}"#)
        let resolved = MCPClientManager.resolveMCPCall(
            toolName: "run_query", arguments: ["query": "select 1", "parameters": ["a": 1]], schema: schema
        )
        XCTAssertEqual(resolved.arguments["query"] as? String, "select 1")
        XCTAssertNotNil(resolved.arguments["parameters"])
    }

    func testWithoutASchemaTheLegacyUnwrappingStillApplies() {
        let resolved = MCPClientManager.resolveMCPCall(toolName: "codegraph_call", arguments: ["tool": "search", "parameters": ["q": "x"]])
        XCTAssertEqual(resolved.name, "search")
    }

    func testMetaToolsAreNeverUnwrapped() {
        let resolved = MCPClientManager.resolveMCPCall(
            toolName: "call_tool_by_name", arguments: ["name": "mail_send", "arguments": ["to": "a"]]
        )
        XCTAssertEqual(resolved.name, "call_tool_by_name")
        XCTAssertEqual(resolved.arguments["name"] as? String, "mail_send")
    }

    func testAStringThatLooksLikeJSONStaysAStringUnlessTheSchemaSaysObject() {
        let schema = MCPArgSchema(json: #"{"type":"object","properties":{"text":{"type":"string"},"config":{"type":"object"}}}"#)!
        let out = MCPToolArgumentDefaults.coerceJSONMaps(
            in: ["text": #"{"a":1}"#, "config": #"{"a":1}"#], schema: schema
        )
        XCTAssertEqual(out["text"] as? String, #"{"a":1}"#)
        XCTAssertEqual((out["config"] as? [String: Any])?["a"] as? Int, 1)
    }

    func testAnOptionalObjectDeclaredWithAnyOfStillGetsItsJSONParsed() {
        let schema = MCPArgSchema(json: #"{"type":"object","properties":{"opts":{"anyOf":[{"type":"object"},{"type":"null"}]},"note":{"anyOf":[{"type":"string"},{"type":"null"}]}}}"#)!
        let out = MCPToolArgumentDefaults.coerceJSONMaps(in: ["opts": #"{"a":1}"#, "note": #"{"a":1}"#], schema: schema)
        XCTAssertNotNil(out["opts"] as? [String: Any])
        XCTAssertEqual(out["note"] as? String, #"{"a":1}"#)
    }

    func testWithoutASchemaCoercionIsUnchanged() {
        let out = MCPToolArgumentDefaults.coerceJSONMaps(in: ["x": #"{"a":1}"#], schema: nil)
        XCTAssertNotNil(out["x"] as? [String: Any])
    }

    /// Built-in tools are not MCP dispatchers: `file_write` of a JSON file must reach the tool as a string.
    func testBuiltInToolArgumentsAreNotCoerced() {
        let json = #"{"path":"package.json","content":"{\"name\":\"a\",\"b\":1}"}"#
        XCTAssertEqual(AgentRunner.sanitizeToolArgumentsJson(toolName: "file_write", argumentsJson: json), json)
        XCTAssertEqual(AgentRunner.sanitizeToolArgumentsJson(toolName: "mcp__srv__create_thing", argumentsJson: json), json)
    }

    func testEmptyOrUntypedSchemasAreNormalised() {
        XCTAssertEqual(MCPSchemaShape.normalized("{}"), MCPSchemaShape.empty)
        XCTAssertEqual(MCPSchemaShape.normalized(nil), MCPSchemaShape.empty)
        let typed = MCPSchemaShape.normalized(#"{"properties":{"a":{"type":"string"}}}"#)
        XCTAssertTrue(typed.contains(#""type":"object""#))
        XCTAssertTrue(typed.contains("properties"))
    }

    // MARK: - Names a provider will accept

    func testLongNamespacedNamesFitTheProviderLimitAndRoundTrip() {
        let id = "1A59C906-04DA-521D-BDA7-7F71B9F9E01C"
        for tool in ["read_file", "create_pull_request_review",
                     "add_pull_request_review_comment_to_pending_review_with_a_very_long_name", "notion.search page"] {
            let name = MCPNamespacedTool.name(serverId: id, toolName: tool)
            XCTAssertLessThanOrEqual(name.count, 64, name)
            XCTAssertTrue(MCPNamespacedTool.isProviderSafe(name), name)
            let parsed = MCPNamespacedTool.parse(name)
            XCTAssertEqual(parsed?.serverId, id, name)
            XCTAssertEqual(parsed?.toolName, tool, name)
            // Deterministic, so a name from an earlier session still means the same tool.
            XCTAssertEqual(name, MCPNamespacedTool.name(serverId: id, toolName: tool))
        }
    }

    func testShortNamesAreLeftAlone() {
        XCTAssertEqual(MCPNamespacedTool.name(serverId: "srv-1", toolName: "read_file"), "mcp__srv-1__read_file")
    }

    func testAShortenedServerIdResolvesByPrefixWhenUnique() {
        let a = MCPServerConfig(id: "1a59c906-aaaa-bbbb-cccc-000000000001", name: "one", command: "npx")
        let b = MCPServerConfig(id: "ffffffff-aaaa-bbbb-cccc-000000000002", name: "two", command: "npx")
        XCTAssertEqual(MCPToolRouting.canonicalServer("1a59c906", in: [a, b])?.id, a.id)
        let clash = MCPServerConfig(id: "1a59c906-zzzz-bbbb-cccc-000000000003", name: "three", command: "npx")
        XCTAssertNil(MCPToolRouting.canonicalServer("1a59c906", in: [a, clash]))
    }

    // MARK: - Approval gate

    /// A write tool called without the `mcp__` prefix ran with no prompt.
    func testABareMCPWriteToolAsksAndABareReadDoesNot() {
        let gmail = server("gmail")
        var settings = AppSettings.default
        settings.mcpServers = [gmail]
        MCPAdvertisedSnapshot.set([gmail.id: ["send_message", "list_labels"]])
        defer { MCPAdvertisedSnapshot.set([:]) }

        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "send_message", settings: settings))
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "gmail.send_message", settings: settings))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "list_labels", settings: settings))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "not_a_tool_anyone_has", settings: settings))
    }

    func testExitingPlanModeNeedsApprovalOnlyWhileInPlanMode() {
        var settings = AppSettings.default
        settings.planModeEnabled = true
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "exit_plan_mode", settings: settings))
        settings.planModeEnabled = false
        XCTAssertNil(AgentRunner.approvalReason(toolName: "exit_plan_mode", settings: settings))
    }

    func testAnApprovalCoversOneCall() {
        XCTAssertFalse(ApprovedCalls.consume("call-x"))
        ApprovedCalls.record("call-x")
        XCTAssertTrue(ApprovedCalls.consume("call-x"))
        XCTAssertFalse(ApprovedCalls.consume("call-x"), "an approval is spent by the call it was for")
        XCTAssertFalse(ApprovedCalls.consume(nil))
    }

    func testApprovingAPendingRequestRecordsIt() async {
        let manager = ToolApprovalManager.shared
        let pending = Task { @MainActor in
            await manager.requestApproval(callId: "audit-c1", toolName: "terminal_command", argumentsJson: "{}", reason: "runs a command")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        manager.resolve(callId: "audit-c1", approved: true)
        let v_pending = await pending.value
        XCTAssertEqual(v_pending, .approved)
        XCTAssertTrue(ApprovedCalls.consume("audit-c1"))
    }

    // MARK: - Unattended scope

    func testAnUnattendedRunRefusesAndReportsItsOwnRefusals() async {
        let manager = ToolApprovalManager.shared
        let (outcome, run) = await manager.runUnattended {
            await manager.requestApproval(callId: "u1", toolName: "file_delete", argumentsJson: "{}", reason: "deletes")
        }
        XCTAssertEqual(outcome, .refusedUnattended)
        XCTAssertEqual(run.map(\.toolName), ["file_delete"])
        XCTAssertFalse(manager.isUnattended, "the scope ends with the run")
    }

    func testNestedUnattendedRunsReportUpward() async {
        let manager = ToolApprovalManager.shared
        let (_, outer) = await manager.runUnattended {
            _ = await manager.runUnattended {
                await manager.requestApproval(callId: "n1", toolName: "run_app", argumentsJson: "{}", reason: "launches")
            }
        }
        XCTAssertEqual(outer.map(\.toolName), ["run_app"])
    }

    /// The user's own chat must not be treated as unattended because something else is running.
    func testAChatOutsideAnUnattendedRunStillWaitsForAPerson() async {
        let manager = ToolApprovalManager.shared
        XCTAssertFalse(manager.isUnattended)
        let chat = Task { @MainActor in
            await manager.requestApproval(callId: "chat-1", toolName: "file_delete", argumentsJson: "{}", reason: "deletes")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        _ = await manager.runUnattended {
            await manager.requestApproval(callId: "bg-1", toolName: "file_delete", argumentsJson: "{}", reason: "deletes")
        }
        XCTAssertEqual(manager.pendingApprovals.map(\.id), ["chat-1"], "the chat's prompt stayed live")
        manager.resolve(callId: "chat-1", approved: false)
        let v_chat = await chat.value
        XCTAssertEqual(v_chat, .rejected)
    }

    func testTwoQuestionsAreBothAnsweredInOrder() async {
        let manager = UserChoiceManager.shared
        manager.cancelAll()
        let first = Task { @MainActor in await manager.request(question: "one?", options: [], callId: "q1") }
        let second = Task { @MainActor in await manager.request(question: "two?", options: [], callId: "q2") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.pending?.id, "q1")
        manager.resolve(answer: "A")
        XCTAssertEqual(manager.pending?.id, "q2")
        manager.resolve(answer: "B")
        let v_first = await first.value
        XCTAssertEqual(v_first, "A")
        let v_second = await second.value
        XCTAssertEqual(v_second, "B")
        XCTAssertNil(manager.pending)
    }

    // MARK: - Visible text and text-written calls

    func testAJSONSnippetInAnAnswerSurvivesAndAToolCallDoesNot() {
        let manifest = "Here:\n```json\n{\"name\": \"my-app\", \"version\": \"1.0.0\"}\n```\nDone."
        XCTAssertEqual(AssistantContentSanitizer.sanitizeVisible(manifest), manifest)
        XCTAssertEqual(AssistantContentSanitizer.sanitizeVisible("{\"name\": \"data\", \"x\": 1}"), "{\"name\": \"data\", \"x\": 1}")

        let call = "```tool_call\n{\"tool\": \"file_list\", \"parameters\": {\"path\": \".\"}}\n```"
        XCTAssertEqual(AssistantContentSanitizer.sanitizeVisible(call), "")
        XCTAssertEqual(
            AssistantContentSanitizer.sanitizeVisible("TOOL_CALL = {\"tool\":\"x\",\"parameters\":{\"a\":{\"b\":1}}} then text"),
            "then text"
        )
    }

    func testAConfigSnippetWithAServerKeyIsNotACall() {
        let config = "```json\n{\"server\": \"localhost\", \"port\": 80}\n```"
        XCTAssertTrue(TextToolCallParser.parse(config) { _ in true }.isEmpty)
        let call = "```json\n{\"mcp\": \"macuse\", \"tool\": \"list_windows\", \"arguments\": {}}\n```"
        XCTAssertEqual(TextToolCallParser.parse(call) { _ in true }.first?.tool, "mcp_call")
    }

    // MARK: - Stuck breaker

    func testOnlyRealEditsResetTheRepeatCounts() {
        for tool in ["file_write", "edit_file", "multi_edit", "write_file", "file_delete"] {
            XCTAssertTrue(AgentRunner.changesFiles(tool), tool)
        }
        for tool in ["build_project", "run_tests", "terminal_command", "git_status", "file_read"] {
            XCTAssertFalse(AgentRunner.changesFiles(tool), tool)
        }
    }

    // MARK: - Effect classification

    func testNounLikeVerbsAfterAReadWordAreReads() {
        for name in ["get_commit", "get_workflow_run", "get_merge_request", "get_post", "list_starred_repositories"] {
            XCTAssertFalse(MCPEffectCatalog.nameSuggestsWrite(name), name)
        }
    }

    func testNewlyRecognisedWriteVerbsAndJoinedActions() {
        for name in ["add_sub_issue", "save_note", "star_repository", "deploy_service", "get_or_create_repository", "list_and_archive"] {
            XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite(name), name)
        }
    }

    func testACommonWordInAServerNameDoesNotPickTheFilesystemTable() {
        XCTAssertNil(MCPEffectCatalog.entry(for: MCPServerConfig(id: "a", name: "Profiles", command: "./x")))
        XCTAssertEqual(MCPEffectCatalog.entry(for: MCPServerConfig(id: "b", name: "Local Files", command: "./x"))?.key, "filesystem")
    }

    /// `retain` writes a memory but shares no token with the mutating-verb list, and a server
    /// named "Hindsight Memory" word-matches the generic `memory` table (built for the reference
    /// `server-memory` package) whose write list doesn't know Hindsight's tool names. Both checks
    /// used to fall through to "read", which let plan mode call it despite being read-only.
    func testRetainIsRecognisedAsAWriteEvenOnAServerNamedMemory() {
        XCTAssertTrue(MCPEffectCatalog.nameSuggestsWrite("retain"))
        let hindsight = MCPServerConfig(id: "mcp-hindsight", name: "Hindsight Memory", command: "", url: "http://127.0.0.1:8888/mcp/swiftopenwork")
        XCTAssertEqual(MCPEffectCatalog.classify(server: hindsight, toolName: "retain", advertised: true), .write)
        XCTAssertEqual(MCPEffectCatalog.classify(server: hindsight, toolName: "recall", advertised: true), .read)
        XCTAssertEqual(MCPEffectCatalog.classify(server: hindsight, toolName: "reflect", advertised: true), .read)
    }

    // MARK: - Stdio buffer, JSON values, lifecycle

    func testAServerRequestReusingOurIdIsNotTakenAsTheAnswer() {
        let buffer = MCPStdioBuffer()
        buffer.append(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#.data(using: .utf8)! + Data([10]))
        XCTAssertNil(buffer.extractJSONRPCResponse(id: 5))
        buffer.append(#"{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":"real"}]}}"#.data(using: .utf8)! + Data([10]))
        XCTAssertEqual(buffer.extractJSONRPCResponse(id: 5), "real")
    }

    func testIntegersZeroAndOneAreNotEncodedAsBooleans() throws {
        let data = try JSONEncoder().encode(AnyCodable(NSNumber(value: 1)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "1")
        let flag = try JSONEncoder().encode(AnyCodable(NSNumber(value: true)))
        XCTAssertEqual(String(decoding: flag, as: UTF8.self), "true")
    }

    func testEditingAServerChangesItsFingerprintButRenamingDoesNot() {
        let base = MCPServerConfig(id: "s", name: "one", command: "npx", args: ["a"], env: ["K": "1"])
        var renamed = base; renamed.name = "two"; renamed.disabledTools = ["x"]
        var edited = base; edited.env["K"] = "2"
        XCTAssertEqual(MCPClientManager.fingerprint(base), MCPClientManager.fingerprint(renamed))
        XCTAssertNotEqual(MCPClientManager.fingerprint(base), MCPClientManager.fingerprint(edited))
    }

    // MARK: - Catalog promotion

    func testPromotedToolsAreScopedToTheRunThatRegisteredThem() async {
        let registry = MCPPromotedToolRegistry.shared
        await registry.reset(owner: "run-a"); await registry.reset(owner: "run-b")
        let tool = MCPPromotedTool(chatName: "mcp__srv__audit_tool", serverId: "srv", serverName: "srv",
                                   executeTool: "call_tool_by_name", injectName: "audit_tool")
        let a = await registry.register([tool], owner: "run-a")
        let b = await registry.register([tool], owner: "run-b")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1, "a second run still gets to announce it")
        await registry.reset(owner: "run-a")
        let stillThere = await registry.lookup("mcp__srv__audit_tool")
        XCTAssertNotNil(stillThere, "run-b's tool survived run-a starting over")
        await registry.reset(owner: "run-b")
        let gone = await registry.lookup("mcp__srv__audit_tool")
        XCTAssertNil(gone)
    }

    func testAPromotedToolKeepsItsOwnNameParameter() {
        let promoted = MCPPromotedTool(
            chatName: "mcp__srv__notes_create", serverId: "srv", serverName: "srv",
            executeTool: "call_tool_by_name", injectName: "notes_create",
            inputSchemaJson: #"{"type":"object","properties":{"name":{"type":"string"}}}"#
        )
        let args = MCPCatalogPromote.dispatchArguments(for: promoted, raw: ["name": "My note"])
        XCTAssertEqual(args["name"] as? String, "notes_create")
        XCTAssertEqual((args["arguments"] as? [String: Any])?["name"] as? String, "My note")
    }

    // MARK: - Processes

    /// A check command whose child outlives it must not stall the loop.
    func testALoopCheckThatTimesOutWithAStrayChildStillReturns() {
        let started = Date()
        let result = LoopCheckCommand.runBlocking("sleep 30 & echo hi; sleep 30", in: NSTemporaryDirectory(), timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 12)
    }

    func testALoopCheckWhoseBackgroundChildKeepsThePipeOpenStillReturns() {
        let started = Date()
        let result = LoopCheckCommand.runBlocking("(sleep 20 &) ; echo done; exit 3", in: NSTemporaryDirectory(), timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(result.output.contains("done"))
    }
}
