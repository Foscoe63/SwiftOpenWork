import XCTest
import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// `code_mode` runs a model-written JavaScript program against the tools. These drive real
/// JavaScript through `CodeModeRuntime` with a fake tool behind the bridge, and check the rules
/// that decide which calls a script may make.
final class CodeModeTests: XCTestCase {

    private func run(
        _ code: String, limits: CodeModeRuntime.Limits = .init(),
        tool: @escaping @Sendable (String, String) async -> Result<String, CodeModeCallFailure> = { name, _ in .success("ran \(name)") }
    ) async -> CodeModeRuntime.Outcome {
        await CodeModeRuntime.run(code: code, limits: limits) { name, args, _ in await tool(name, args) }
    }

    // MARK: - Runtime

    func testReturnsAStringAsIs() async {
        let outcome = await run("return 'hello';")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.value, "hello")
    }

    func testReturnsAnObjectAsJSON() async {
        let outcome = await run("return {a: 1, b: [2, 3]};")
        let data = try? JSONSerialization.jsonObject(with: Data((outcome.value ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(data?["a"] as? Int, 1)
    }

    func testNoReturnIsEmptyNotAnError() async {
        let outcome = await run("const x = 1;")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.value, "")
    }

    func testAToolCallReturnsItsOutput() async {
        let outcome = await run("return await tools.file_read({path: 'a.txt'});") { name, args in
            .success("\(name):\(args)")
        }
        XCTAssertEqual(outcome.value, #"file_read:{"path":"a.txt"}"#)
        XCTAssertEqual(outcome.callCount, 1)
    }

    func testAFailedToolCallThrowsAnErrorTheScriptCanCatch() async {
        let outcome = await run("""
            try { await tools.file_read({path: 'x'}); return 'no'; }
            catch (e) { return 'caught: ' + e.message; }
            """) { _, _ in .failure(CodeModeCallFailure(message: "missing")) }
        XCTAssertEqual(outcome.value, "caught: missing")
    }

    func testAnUncaughtToolFailureFailsTheScript() async {
        let outcome = await run("await tools.grep({});") { _, _ in .failure(CodeModeCallFailure(message: "boom")) }
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.error?.contains("boom") == true, outcome.error ?? "")
    }

    func testPromiseAllRunsCallsTogether() async {
        let outcome = await run("""
            const r = await Promise.all(['a', 'b', 'c'].map(n => tools.read({n})));
            return r.length;
            """)
        XCTAssertEqual(outcome.value, "3")
        XCTAssertEqual(outcome.callCount, 3)
    }

    func testLoopsAndFiltersStayInsideTheScript() async {
        let outcome = await run("""
            let kept = 0;
            for (let i = 0; i < 5; i++) {
                const out = await tools.count({i});
                if (Number(out) % 2 === 0) kept++;
            }
            return kept;
            """) { _, args in
            let i = (try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])?["i"] as? Int ?? 0
            return .success(String(i))
        }
        XCTAssertEqual(outcome.value, "3")
    }

    func testConsoleOutputIsCaptured() async {
        let outcome = await run("console.log('a', {b: 1}); console.warn('careful'); return 1;")
        XCTAssertEqual(outcome.logs.first, "a {\n  \"b\": 1\n}")
        XCTAssertEqual(outcome.logs.last, "[warn] careful")
    }

    func testASyntaxErrorIsReportedWithoutRunningAnything() async {
        let outcome = await run("const = ;") { _, _ in XCTFail("ran a tool"); return .success("") }
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.callCount, 0)
    }

    func testAThrownErrorIsReported() async {
        let outcome = await run("throw new Error('nope');")
        XCTAssertEqual(outcome.error, "Error: nope")
    }

    func testTheCallCapStopsARunawayLoop() async {
        var limits = CodeModeRuntime.Limits()
        limits.maxCalls = 5
        let outcome = await run("for (let i = 0; i < 50; i++) await tools.noop({});", limits: limits)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.callCount, 5)
        XCTAssertTrue(outcome.error?.contains("more than 5 tool calls") == true, outcome.error ?? "")
    }

    func testAScriptThatNeverAwaitsIsStopped() async {
        var limits = CodeModeRuntime.Limits()
        limits.scriptSeconds = 1
        limits.wallSeconds = 20
        let started = Date()
        let outcome = await run("while (true) {}", limits: limits)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testAScriptWaitingOnAToolIsStoppedByTheWallClock() async {
        var limits = CodeModeRuntime.Limits()
        limits.wallSeconds = 1
        let outcome = await run("await tools.slow({});", limits: limits) { _, _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return .success("late")
        }
        XCTAssertTrue(outcome.error?.contains("longer than") == true, outcome.error ?? "")
    }

    func testTheContextHasNoWayOutExceptTools() async {
        let outcome = await run("""
            return [typeof fetch, typeof require, typeof process, typeof XMLHttpRequest, typeof __native, typeof __log].join(',');
            """)
        XCTAssertEqual(outcome.value, "undefined,undefined,undefined,undefined,undefined,undefined")
    }

    func testToolNamesWithPunctuationWorkThroughBrackets() async {
        let outcome = await run("return await tools['mcp__server__do-thing']({});") { name, _ in .success(name) }
        XCTAssertEqual(outcome.value, "mcp__server__do-thing")
    }

    func testAnOversizedResultIsTruncated() async {
        var limits = CodeModeRuntime.Limits()
        limits.maxResultCharacters = 100
        let outcome = await run("return 'x'.repeat(10000);", limits: limits)
        XCTAssertTrue(outcome.value?.contains("result truncated") == true)
        XCTAssertLessThan(outcome.value?.count ?? .max, 300)
    }

    func testSleepWaitsThenContinues() async {
        let outcome = await run("await sleep(50); return 'done';")
        XCTAssertEqual(outcome.value, "done")
    }

    // MARK: - Policy

    func testScriptsCannotCallToolsThatNeedTheAgentOrPerson() {
        let settings = AppSettings()
        for name in ["code_mode", "ask_user", "exit_plan_mode", "worktree_merge", "agent_spawn", "send_input"] {
            XCTAssertNotNil(CodeModePolicy.refusal(toolName: name, offered: nil, settings: settings), name)
        }
        // An alias resolves to the same tool, so it is refused the same way.
        XCTAssertNotNil(CodeModePolicy.refusal(toolName: "functions.ask_user", offered: nil, settings: settings))
        XCTAssertNil(CodeModePolicy.refusal(toolName: "file_read", offered: nil, settings: settings))
    }

    func testPlanModeStillBlocksWritesFromAScript() {
        var settings = AppSettings()
        settings.planModeEnabled = true
        XCTAssertNotNil(CodeModePolicy.refusal(toolName: "bash", offered: nil, settings: settings))
        XCTAssertNotNil(CodeModePolicy.refusal(toolName: "write", offered: nil, settings: settings))
        XCTAssertNil(CodeModePolicy.refusal(toolName: "grep", offered: nil, settings: settings))
    }

    func testAToolTheAgentDoesNotHaveIsRefused() {
        let settings = AppSettings()
        XCTAssertNotNil(CodeModePolicy.refusal(toolName: "rm", offered: ["file_read"], settings: settings))
        XCTAssertNil(CodeModePolicy.refusal(toolName: "read", offered: ["file_read"], settings: settings))
    }

    func testSignatureShowsRequiredArgumentsFirst() {
        let schema = #"{"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"integer"}},"required":["path"]}"#
        XCTAssertEqual(CodeModePolicy.signature(name: "grep", schemaJson: schema), "tools.grep({ path: string, limit?: integer })")
        XCTAssertEqual(CodeModePolicy.signature(name: "git_status", schemaJson: #"{"type":"object","properties":{}}"#), "tools.git_status()")
    }

    func testReportLeadsWithTheResultThenLogsThenCalls() {
        let outcome = CodeModeRuntime.Outcome(value: "42", error: nil, logs: ["hi"], callCount: 1)
        let text = CodeModePolicy.report(outcome, trace: ["1. grep ok 3ms"])
        XCTAssertTrue(text.hasPrefix("42"))
        XCTAssertTrue(text.contains("[console]\nhi"))
        XCTAssertTrue(text.contains("[1 tool call]\n1. grep ok 3ms"))
    }

    func testCodeModeIsOffUntilSwitchedOn() {
        XCTAssertFalse(AppSettings().enableCodeMode)
        XCTAssertNotNil(ToolHandlerRegistry.handlers["code_mode"])
    }

    // MARK: - Gate

    func testTheGateRunsReadsTogetherButWritesAlone() async {
        let gate = CodeModeGate()
        await gate.acquire(exclusive: false)
        await gate.acquire(exclusive: false)
        let writer = Task { await gate.acquire(exclusive: true); return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.release(exclusive: false)
        await gate.release(exclusive: false)
        let acquired = await writer.value
        XCTAssertTrue(acquired)
        await gate.release(exclusive: true)
    }
}
