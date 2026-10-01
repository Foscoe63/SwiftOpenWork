import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

final class InteractiveCommandTests: XCTestCase {
    func testBoolArgumentAcceptsWhatModelsActuallySend() {
        XCTAssertEqual(ToolExecutionEngine.boolArgument(true), true)
        XCTAssertEqual(ToolExecutionEngine.boolArgument("true"), true)
        XCTAssertEqual(ToolExecutionEngine.boolArgument("False"), false)
        XCTAssertEqual(ToolExecutionEngine.boolArgument(1), true)
        XCTAssertEqual(ToolExecutionEngine.boolArgument(0), false)
        XCTAssertNil(ToolExecutionEngine.boolArgument("maybe"))
        XCTAssertNil(ToolExecutionEngine.boolArgument(nil))
    }

    func testIdleSecondsIsClamped() {
        XCTAssertEqual(ToolExecutionEngine.idleSeconds(from: nil), 3)
        XCTAssertEqual(ToolExecutionEngine.idleSeconds(from: 0), 1)
        XCTAssertEqual(ToolExecutionEngine.idleSeconds(from: 500), 60)
        XCTAssertEqual(ToolExecutionEngine.idleSeconds(from: "10"), 10)
    }

    func testInputBytes() {
        XCTAssertEqual(InteractiveInput.bytes(text: "yes", pressEnter: true, key: nil), "yes\r")
        XCTAssertEqual(InteractiveInput.bytes(text: "yes", pressEnter: false, key: nil), "yes")
        XCTAssertEqual(InteractiveInput.bytes(text: "", pressEnter: false, key: nil), "")
        XCTAssertEqual(InteractiveInput.bytes(text: "", pressEnter: true, key: "down"), "\u{1B}[B", "a key replaces the implicit Enter")
        XCTAssertEqual(InteractiveInput.bytes(text: "", pressEnter: true, key: "Ctrl-C"), "\u{03}")
        XCTAssertNil(InteractiveInput.bytes(text: "", pressEnter: true, key: "banana"))
    }

    func testFormattingDistinguishesEveryOutcome() {
        let ok = InteractiveCommandFormatting.format(InteractiveCommandResult(output: " done \n", exitCode: 0), timeoutSeconds: 600)
        XCTAssertTrue(ok.success); XCTAssertEqual(ok.output, "done"); XCTAssertNil(ok.error)

        let failed = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "x", exitCode: 2), timeoutSeconds: 600)
        XCTAssertFalse(failed.success); XCTAssertEqual(failed.error, "Process exited with code 2")

        let waiting = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "name? ", exitCode: nil, stillRunning: true), timeoutSeconds: 600)
        XCTAssertTrue(waiting.success, "a waiting command is not a failure")
        XCTAssertTrue(waiting.output.hasPrefix("name?"))
        XCTAssertTrue(waiting.output.contains("send_input"))

        let silent = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "", exitCode: nil, stillRunning: true), timeoutSeconds: 600)
        XCTAssertTrue(silent.output.contains("send_input"))

        let refused = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "", exitCode: nil, refusal: "nope"), timeoutSeconds: 600)
        XCTAssertFalse(refused.success); XCTAssertEqual(refused.error, "nope")

        let timedOut = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "p", exitCode: nil, timedOut: true), timeoutSeconds: 600)
        XCTAssertFalse(timedOut.success); XCTAssertTrue(timedOut.error?.contains("600s") ?? false)

        let stopped = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "p", exitCode: nil, cancelled: true), timeoutSeconds: 600)
        XCTAssertTrue(stopped.error?.contains("stopped") ?? false)
    }

    func testOversizedOutputKeepsTheEnd() {
        let big = String(repeating: "a", count: 300_000) + "TAIL"
        let out = InteractiveCommandFormatting.format(InteractiveCommandResult(output: big, exitCode: 0), timeoutSeconds: 1).output
        XCTAssertEqual(out.count, InteractiveCommandFormatting.maxCharacters)
        XCTAssertTrue(out.hasSuffix("TAIL"))
    }

    @MainActor
    func testSendInputIsKnownToTheDispatcherAndNeverRunsInParallel() {
        XCTAssertTrue(ToolCallRepair.builtInNames.contains("send_input"))
        XCTAssertEqual(ToolCallRepair.canonicalName("send_input"), "send_input")
        XCTAssertFalse(AgentRunner.isParallelSafe("send_input"))
    }

    @MainActor
    func testSendInputAsksUnlessTheUserRunsUnrestricted() {
        func reason(_ level: TerminalSafetyLevel) -> String? {
            var settings = AppSettings.default
            settings.terminalSafetyLevel = level
            return AgentRunner.approvalReason(toolName: "send_input", argumentsJson: "{\"text\":\"y\"}", settings: settings, sessionId: "s", workspaceRoot: "/tmp")
        }
        XCTAssertNotNil(reason(.alwaysAsk))
        XCTAssertNotNil(reason(.safeOnly))
        XCTAssertNil(reason(.allowAll))
    }
}

/// Records what the dispatcher hands the runner, so the tool layer can be tested without a terminal.
private final class RecordingRunner: InteractiveCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [(String, TimeInterval, Bool)] = []
    private var _runs: [(String, [String], TimeInterval)] = []
    var inputs: [(String, TimeInterval, Bool)] { lock.withLock { _inputs } }
    var runs: [(String, [String], TimeInterval)] { lock.withLock { _runs } }

    func run(executable: String, arguments: [String], cwd: String, environment: [String: String],
             displayCommand: String, timeoutSeconds: TimeInterval, idleSeconds: TimeInterval) async -> InteractiveCommandResult {
        lock.withLock { _runs.append((displayCommand, arguments, idleSeconds)) }
        return InteractiveCommandResult(output: "name? ", exitCode: nil, stillRunning: true)
    }

    func sendInput(_ input: String, idleSeconds: TimeInterval, terminate: Bool) async -> InteractiveCommandResult {
        lock.withLock { _inputs.append((input, idleSeconds, terminate)) }
        return InteractiveCommandResult(output: "ok", exitCode: 0)
    }
}

final class SendInputDispatchTests: XCTestCase {
    private let root = NSTemporaryDirectory() + "sendinput-\(UUID().uuidString)"
    private var workspace: Workspace { Workspace(id: "w", name: "W", folderPath: root) }
    private let agent = Agent(name: "Runner", role: "executor")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    private func execute(_ tool: String, _ json: String, level: TerminalSafetyLevel) async -> ToolExecutionResult {
        let original = PersistenceManager.shared.loadSettings()
        var s = original
        s.terminalSafetyLevel = level
        s.shellSandboxMode = .off
        PersistenceManager.shared.saveSettings(s)
        defer { PersistenceManager.shared.saveSettings(original) }
        return await ToolExecutionEngine.shared.execute(
            toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent, callId: "c"
        )
    }

    func testInteractiveRunReturnsStillRunningAndPassesIdleSeconds() async {
        let runner = RecordingRunner()
        InteractiveCommandRegistry.register(runner)
        defer { InteractiveCommandRegistry.register(nil) }
        let result = await execute("terminal_command", #"{"command":"npm init","interactive":true,"idle_seconds":7}"#, level: .allowAll)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("name?"))
        XCTAssertTrue(result.output.contains("send_input"))
        XCTAssertEqual(runner.runs.first?.2, 7)
        XCTAssertEqual(runner.runs.first?.1.last, "npm init")
    }

    func testSendInputTypesTextWithEnterAndReturnsTheNextOutput() async {
        let runner = RecordingRunner()
        InteractiveCommandRegistry.register(runner)
        defer { InteractiveCommandRegistry.register(nil) }
        let result = await execute("send_input", #"{"text":"my-app"}"#, level: .allowAll)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "ok")
        XCTAssertEqual(runner.inputs.first?.0, "my-app\r")
        XCTAssertEqual(runner.inputs.first?.1, 3)
        XCTAssertEqual(runner.inputs.first?.2, false)
    }

    func testSendInputKeyAndTerminateAndUnknownKey() async {
        let runner = RecordingRunner()
        InteractiveCommandRegistry.register(runner)
        defer { InteractiveCommandRegistry.register(nil) }
        _ = await execute("send_input", #"{"key":"down"}"#, level: .allowAll)
        XCTAssertEqual(runner.inputs.last?.0, "\u{1B}[B")
        _ = await execute("send_input", #"{"terminate":true}"#, level: .allowAll)
        XCTAssertEqual(runner.inputs.last?.2, true)
        let bad = await execute("send_input", #"{"key":"banana"}"#, level: .allowAll)
        XCTAssertFalse(bad.success)
        XCTAssertTrue(bad.error?.contains("Known keys") ?? false)
        XCTAssertEqual(runner.inputs.count, 2, "an unknown key must not reach the terminal")
    }

    func testSendInputIsRefusedUnderTheRestrictiveSafetyLevels() async {
        let runner = RecordingRunner()
        InteractiveCommandRegistry.register(runner)
        defer { InteractiveCommandRegistry.register(nil) }
        for level in [TerminalSafetyLevel.safeOnly, .alwaysAsk] {
            let result = await execute("send_input", #"{"text":"rm -rf ~"}"#, level: level)
            XCTAssertFalse(result.success, "\(level)")
        }
        XCTAssertTrue(runner.inputs.isEmpty, "nothing may reach the terminal when the policy refuses")
    }

    func testSendInputCannotWriteOutsideTheSandboxedWorkspace() async {
        let runner = RecordingRunner()
        InteractiveCommandRegistry.register(runner)
        defer { InteractiveCommandRegistry.register(nil) }
        let original = PersistenceManager.shared.loadSettings()
        var s = original
        s.terminalSafetyLevel = .allowAll
        s.sandboxAgentFileSystem = true
        PersistenceManager.shared.saveSettings(s)
        defer { PersistenceManager.shared.saveSettings(original) }
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "send_input", argumentsJson: #"{"text":"echo hi > /etc/evil"}"#,
            workspace: workspace, currentAgent: agent, callId: "c"
        )
        XCTAssertFalse(result.success)
        XCTAssertTrue(runner.inputs.isEmpty)
    }
}
