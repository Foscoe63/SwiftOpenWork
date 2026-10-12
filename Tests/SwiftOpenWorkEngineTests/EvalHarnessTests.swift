import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// The mechanics of the eval harness, and — behind environment variables — a real run.
final class EvalHarnessTests: XCTestCase {

    private static var tasksDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals/tasks")
    }

    func testShippedTasksAreWellFormedAndStartRed() async throws {
        let tasks = EvalHarness.loadTasks(from: Self.tasksDirectory)
        XCTAssertGreaterThanOrEqual(tasks.count, 5)
        XCTAssertEqual(Set(tasks.map(\.task.id)).count, tasks.count, "ids are unique")
        for (task, folder) in tasks {
            XCTAssertEqual(folder.lastPathComponent, task.id)
            XCTAssertFalse(task.prompt.isEmpty)
            let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eval-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: workspace) }
            try EvalHarness.prepare(task: task, folder: folder, into: workspace)
            // A task whose verifier already passes measures nothing.
            let before = await EvalHarness.verify(task: task, in: workspace)
            XCTAssertFalse(before.passed, "\(task.id) must fail before the agent does anything")
        }
    }

    func testVerifierPassesOnceTheWorkIsDone() async throws {
        let tasks = EvalHarness.loadTasks(from: Self.tasksDirectory)
        let (task, folder) = try XCTUnwrap(tasks.first { $0.task.id == "fix-off-by-one" })
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try EvalHarness.prepare(task: task, folder: folder, into: workspace)
        let file = workspace.appendingPathComponent("sum_to.py")
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "range(1, n)", with: "range(1, n + 1)").write(to: file, atomically: true, encoding: .utf8)
        let after = await EvalHarness.verify(task: task, in: workspace)
        XCTAssertTrue(after.passed, after.output)
    }

    func testComparisonNamesRegressionsAndFixes() {
        func outcome(_ id: String, _ passed: Bool) -> EvalHarness.Outcome {
            .init(taskId: id, passed: passed, seconds: 1, toolCalls: 2, promptTokens: 3, completionTokens: 4, error: nil, verifierOutput: "")
        }
        let baseline = EvalHarness.Report(model: "m", provider: "p", startedAt: Date(), outcomes: [outcome("a", true), outcome("b", false), outcome("c", true)])
        let current = EvalHarness.Report(model: "m", provider: "p", startedAt: Date(), outcomes: [outcome("a", false), outcome("b", true), outcome("c", true), outcome("new", true)])
        let comparison = EvalHarness.compare(baseline: baseline, current: current)
        XCTAssertEqual(comparison.regressions, ["a"])
        XCTAssertEqual(comparison.fixes, ["b"])
        XCTAssertEqual(comparison.unchanged, 1)
        XCTAssertEqual(current.passed, 3)
        XCTAssertTrue(current.summary().contains("| a | **FAIL**"))
    }

    // MARK: - A real run

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var session: Session
        init(_ s: Session) { session = s }
        func update(_ message: ChatMessage) {
            lock.lock(); defer { lock.unlock() }
            if let i = session.messages.firstIndex(where: { $0.id == message.id }) { session.messages[i] = message } else { session.messages.append(message) }
        }
    }

    /// `SWIFTOPENWORK_EVAL_URL=http://127.0.0.1:11500/v1 SWIFTOPENWORK_EVAL_MODEL=<id> [SWIFTOPENWORK_EVAL_KEY=…]
    ///  [SWIFTOPENWORK_EVAL_ONLY=id1,id2] [SWIFTOPENWORK_EVAL_OUT=report.json] [SWIFTOPENWORK_EVAL_BASELINE=old.json]`
    /// Any OpenAI-compatible server will do, including this app's own local API.
    func testRunAgainstARealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SWIFTOPENWORK_EVAL_URL"], let modelId = env["SWIFTOPENWORK_EVAL_MODEL"] else {
            throw XCTSkip("Set SWIFTOPENWORK_EVAL_URL and SWIFTOPENWORK_EVAL_MODEL to run the eval; see Evals/README.md")
        }
        // Tools run unattended here: nobody is at the keyboard to approve them.
        var settings = PersistenceManager.shared.loadSettings()
        settings.terminalSafetyLevel = .allowEverything
        PersistenceManager.shared.saveSettings(settings)

        let provider = ModelProvider(
            id: "eval", name: "Eval", type: .cloud, kind: .custom, baseUrl: url, apiKey: env["SWIFTOPENWORK_EVAL_KEY"] ?? "",
            models: [ModelInfo(id: modelId, name: modelId, providerId: "eval")]
        )
        let only = env["SWIFTOPENWORK_EVAL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let agent = Agent(id: "eval-coder", name: "Coder", systemPrompt: "You are a careful software engineer. Use your tools to inspect and change files, and run the tests before you finish.")
        var outcomes: [EvalHarness.Outcome] = []

        for (task, folder) in EvalHarness.loadTasks(from: Self.tasksDirectory) where only?.contains(task.id) ?? true {
            let workspaceURL = URL(fileURLWithPath: ToolExecutionEngine.canonicalPath(NSTemporaryDirectory())).appendingPathComponent("eval-\(task.id)-\(UUID().uuidString.prefix(6))")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }
            try EvalHarness.prepare(task: task, folder: folder, into: workspaceURL)
            let workspace = Workspace(name: task.id, folderPath: workspaceURL.path)
            var session = Session(agentId: agent.id)
            session.messages.append(ChatMessage(sessionId: session.id, role: .user, content: task.prompt))
            let box = Box(session)
            let started = Date()
            let run = Task {
                await AgentRunner.shared.run(
                    session: box.session, agent: agent, provider: provider, model: provider.models[0], workspace: workspace,
                    allAgents: [agent], reasoningOverride: .off,
                    onMessageUpdated: box.update, onSubAgentTaskCreated: { _ in }, onSubAgentTaskUpdated: { _ in }, onInterAgentMessage: { _ in }
                )
            }
            let timeout = Task { try? await Task.sleep(nanoseconds: UInt64(task.timeoutSeconds) * 1_000_000_000); run.cancel() }
            await run.value
            timeout.cancel()

            let replies = box.session.messages.filter { $0.role == .assistant }
            let verdict = await EvalHarness.verify(task: task, in: workspaceURL)
            let timedOut = Date().timeIntervalSince(started) >= Double(task.timeoutSeconds)
            outcomes.append(.init(
                taskId: task.id, passed: verdict.passed, seconds: Date().timeIntervalSince(started),
                toolCalls: replies.reduce(0) { $0 + $1.toolCalls.count },
                promptTokens: replies.reduce(0) { $0 + $1.promptTokens }, completionTokens: replies.reduce(0) { $0 + $1.completionTokens },
                error: timedOut ? "timed out" : replies.last(where: \.isError)?.content,
                verifierOutput: verdict.output
            ))
        }

        let report = EvalHarness.Report(model: modelId, provider: url, startedAt: Date(), outcomes: outcomes)
        print("\n" + report.summary() + "\n")
        let out = URL(fileURLWithPath: env["SWIFTOPENWORK_EVAL_OUT"] ?? NSTemporaryDirectory() + "swiftopenwork-eval.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: out)
        print("Report written to \(out.path)")
        if let path = env["SWIFTOPENWORK_EVAL_BASELINE"], let data = FileManager.default.contents(atPath: path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let baseline = try? decoder.decode(EvalHarness.Report.self, from: data) {
                print("Against baseline: " + EvalHarness.compare(baseline: baseline, current: report).summary)
            }
        }
    }
}
