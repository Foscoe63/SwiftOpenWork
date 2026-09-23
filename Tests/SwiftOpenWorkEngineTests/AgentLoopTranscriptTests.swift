import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Each test here reproduces something one exported session showed: a local model asked to fix
/// a terminal emulator removed one line, looped for most of an hour, wiped its own plan, repeated
/// its opening paragraph seven times in one reply and lost its KV cache on almost every step.
final class AgentLoopTranscriptTests: XCTestCase {

    private var root: String!
    private var workspace: Workspace!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "loop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Test", folderPath: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func run(_ tool: String, _ json: String) async -> ToolExecutionResult {
        await ToolExecutionEngine.shared.execute(
            toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: Agent(name: "Test")
        )
    }

    // MARK: - todo_write

    /// `todo_write {}` four times in a row wiped a ten-item plan, each reported as "cleared".
    func testTodoWriteWithoutItemsIsAnErrorAndChangesNothing() async {
        let result = await run("todo_write", "{}")
        XCTAssertFalse(result.success)
        XCTAssertNil(result.sessionTodos, "a list the model did not send must not replace the user's")
        XCTAssertTrue(result.error?.contains("left unchanged") ?? false, result.error ?? "")
    }

    func testTodoWriteWithAnEmptyListStillClears() async {
        let result = await run("todo_write", #"{"items":[]}"#)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.sessionTodos, [])
    }

    func testTodoWriteAcceptsItemsSentAsAJSONString() async {
        let result = await run("todo_write", #"{"items":"[{\"content\":\"Fix bell\",\"status\":\"pending\"}]"}"#)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(result.sessionTodos?.map(\.content), ["Fix bell"])
    }

    func testTodoWriteWithOnlyMalformedItemsDoesNotClear() async {
        let result = await run("todo_write", #"{"items":[{"status":"pending"}]}"#)
        XCTAssertFalse(result.success)
        XCTAssertNil(result.sessionTodos)
    }

    // MARK: - Repeat detection

    /// The same script was read eleven times by alternating aliases and key order.
    func testAliasesKeyOrderAndNumericStringsShareASignature() {
        let a = AgentRunner.callSignature("file_read", #"{"path":"/w/a.sh","offset":80,"limit":30}"#)
        let b = AgentRunner.callSignature("read_file", #"{"limit":"30.0","offset":"80","path":"/w/a.sh"}"#)
        let c = AgentRunner.callSignature("file_read", #"{"filepath":"/w/a.sh","offset":80.0,"limit":30}"#)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func testDifferentArgumentsStillDiffer() {
        XCTAssertNotEqual(
            AgentRunner.callSignature("file_read", #"{"path":"/w/a.sh"}"#),
            AgentRunner.callSignature("file_read", #"{"path":"/w/b.sh"}"#)
        )
        XCTAssertNotEqual(
            AgentRunner.callSignature("file_read", #"{"path":"/w/a.sh","offset":80}"#),
            AgentRunner.callSignature("file_read", #"{"path":"/w/a.sh","offset":85}"#)
        )
    }

    // MARK: - Arguments

    func testWholeNumberStringsAndDoublesAreIntegers() {
        XCTAssertEqual(ToolExecutionEngine.intArgument("80.0"), 80)
        XCTAssertEqual(ToolExecutionEngine.intArgument(" 12 "), 12)
        XCTAssertEqual(ToolExecutionEngine.intArgument(30.0), 30)
        XCTAssertNil(ToolExecutionEngine.intArgument("80.5"))
        XCTAssertNil(ToolExecutionEngine.intArgument("eighty"))
    }

    /// `"offset":"85.0"` was dropped and the whole file came back from line 1.
    func testFileReadHonoursAnOffsetSentAsADecimalString() async throws {
        let body = (1...100).map { "line \($0)" }.joined(separator: "\n")
        try body.write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        let result = await run("file_read", #"{"path":"f.txt","offset":"85.0","limit":"2.0"}"#)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("line 85"), result.output)
        XCTAssertFalse(result.output.contains("line 1\n"), result.output)
    }

    /// `ProTerm/Source/SSHSessionManager.swift` arrived as `ProTermSourceSSHSessionManager.swift`,
    /// twice, with a glob that had found the right file in between.
    func testAMissingPathNamesTheFileItMostLikelyMeant() async throws {
        try FileManager.default.createDirectory(atPath: root + "/ProTerm/Source", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/ProTerm/Source/SSHSessionManager.swift", atomically: true, encoding: .utf8)

        let mangled = await run("file_read", #"{"path":"ProTermSourceSSHSessionManager.swift"}"#)
        XCTAssertTrue(mangled.error?.contains("Did you mean: `ProTerm/Source/SSHSessionManager.swift`") ?? false, mangled.error ?? "")

        let wrongFolder = await run("file_read", #"{"path":"Source/SSHSessionManager.swift"}"#)
        XCTAssertTrue(wrongFolder.error?.contains("ProTerm/Source/SSHSessionManager.swift") ?? false, wrongFolder.error ?? "")

        let nothingLikeIt = await run("file_read", #"{"path":"Nope.swift"}"#)
        XCTAssertTrue(nothingLikeIt.error?.contains("use `glob`") ?? false, nothingLikeIt.error ?? "")
    }

    // MARK: - Folding

    /// A sliding window folded one result per step, and every fold reset the local cache.
    func testFoldingWaitsForABatch() {
        let stamp = Date(timeIntervalSince1970: 0)
        let all = (0..<9).map {
            ChatMessage(id: "t\($0)", sessionId: "s", role: .tool, content: String(repeating: "x", count: 900), timestamp: stamp)
        }
        let seven = Array(all.prefix(7))
        XCTAssertEqual(ContextCompactor.foldOldToolResults(seven), seven, "three due, below the batch")

        let folded = ContextCompactor.foldOldToolResults(Array(all.prefix(8)))
        XCTAssertEqual(folded.prefix(4).filter { $0.content.contains("compacted") }.count, 4)
        XCTAssertFalse(folded.suffix(4).contains { $0.content.contains("compacted") })

        // Once folded, the next step changes nothing until another batch is due.
        let next = folded + [all[8]]
        XCTAssertEqual(ContextCompactor.foldOldToolResults(next), next)
    }

    // MARK: - Call / result pairing

    func testResultsPairWithTheCallsInFrontOfThem() {
        let call = ToolCallInfo(id: "c1", toolName: "file_read", argumentsJson: #"{"path":"a"}"#)
        let unanswered = ToolCallInfo(id: "c2", toolName: "glob")
        let messages = [
            ChatMessage(sessionId: "s", role: .user, content: "go"),
            ChatMessage(sessionId: "s", role: .assistant, content: "", toolCalls: [call, unanswered]),
            ChatMessage(id: "c1", sessionId: "s", role: .tool, content: "contents"),
            ChatMessage(id: "orphan", sessionId: "s", role: .tool, content: "from an old transcript"),
        ]
        let pairing = ToolCallPairing(messages)
        XCTAssertEqual(pairing.answeredCalls(of: messages[1]).map(\.id), ["c1"])
        XCTAssertTrue(pairing.isAnswer(messages[2]))
        XCTAssertFalse(pairing.isAnswer(messages[3]))
    }

    func testAUserTurnClosesTheCallsBeforeIt() {
        let messages = [
            ChatMessage(sessionId: "s", role: .assistant, content: "", toolCalls: [ToolCallInfo(id: "c1", toolName: "glob")]),
            ChatMessage(sessionId: "s", role: .user, content: "interrupting"),
            ChatMessage(id: "c1", sessionId: "s", role: .tool, content: "late"),
        ]
        XCTAssertFalse(ToolCallPairing(messages).isAnswer(messages[2]))
    }

    // MARK: - Narration

    /// Narration hidden while tools ran came back when the turn finished: seven copies of
    /// "# SSH Password Security Fix 🔐 / Let me examine…" above the answer.
    @MainActor
    func testNarrationHiddenDuringTheTurnStaysHiddenAtTheEnd() {
        var final: ChatMessage?
        let acc = AgentStreamAccumulator(
            initialMessage: ChatMessage(sessionId: "s", role: .assistant, content: ""),
            onUpdate: { final = $0 }
        )
        for _ in 0..<3 {
            let before = acc.fullText.count
            acc.applyChunk(LLMStreamChunk(deltaText: "Let me examine the script."))
            acc.hideTurnNarration(beforeLength: before)
        }
        let before = acc.fullText.count
        acc.applyChunk(LLMStreamChunk(deltaText: "Removed the environment variable."))
        XCTAssertEqual(acc.stepText(from: before), "Removed the environment variable.")
        acc.finalize()

        XCTAssertEqual(final?.content, "Removed the environment variable.")
        XCTAssertTrue(final?.reasoning?.contains("Let me examine the script.") ?? false)
    }

    // MARK: - Sub-agent reports

    func testASubAgentReportNamingARefusedWriteIsFlagged() {
        var outcome = SubAgentExecutor.Outcome(
            succeeded: true,
            summary: "Report Location: `/w/deep_analysis_report.md`",
            toolCallsMade: ["file_write"], filesChanged: [], refusedActions: ["file_write — This modifies files on disk."],
            worktreePath: nil, branch: nil, iterations: 3, stoppedBecause: "completed", durationMs: 1
        )
        outcome.refusedWritePaths = ["/w/deep_analysis_report.md"]
        XCTAssertTrue(outcome.report.contains("the file was not created"), outcome.report)

        outcome.refusedWritePaths = ["/w/other.md"]
        XCTAssertFalse(outcome.report.contains("the file was not created"), outcome.report)
    }

    func testChangesLeftOnABranchAreSaidToBeUnmerged() {
        let outcome = SubAgentExecutor.Outcome(
            succeeded: false, summary: "", toolCallsMade: ["edit_file"], filesChanged: ["ProTerm/Source/ANSIParser.swift"],
            refusedActions: [], worktreePath: "/w/.wt/sub", branch: "swiftopenwork/sub-x", iterations: 8,
            stoppedBecause: "ran out of time after 600s", durationMs: 1
        )
        XCTAssertTrue(outcome.report.contains("only on branch `swiftopenwork/sub-x`"), outcome.report)
    }

    func testAnUnfinishedSubAgentSaysItsWorkIsNotCarriedForward() {
        let outcome = SubAgentExecutor.Outcome(
            succeeded: false, summary: "", toolCallsMade: ["edit_file"], filesChanged: ["a.swift"],
            refusedActions: [], worktreePath: "/w/.wt/sub", branch: "swiftopenwork/sub-x", baseCommit: "abc1234",
            iterations: 8, stoppedBecause: "ran out of time after 600s", durationMs: 1
        )
        XCTAssertTrue(outcome.report.contains("will not see this work"), outcome.report)
        XCTAssertTrue(outcome.report.contains("diff abc1234"), outcome.report)
    }

    /// The lead handed ten features to one sub-agent with an 8-step budget it had never been told.
    func testTheLeadIsToldTheSubAgentBudget() {
        let coder = Agent(id: "coder-agent", name: "Coder")
        let lead = Agent(id: "lead", name: "Lead", subAgentIds: ["coder-agent"], autoDelegate: true)
        let provider = ModelProvider(id: "p", name: "p", type: .local, kind: .omlx, baseUrl: "", apiKey: "", isEnabled: true, models: [])
        let section = AgentRunner.teamPromptSection(agent: lead, allAgents: [lead, coder], provider: provider, budget: (steps: 8, minutes: 10))
        XCTAssertTrue(section.contains("8 steps and 10 minutes"), section)
        XCTAssertTrue(section.contains("never a list of features"), section)
    }

    func testOnlyAnUnreachedModelCountsAsFailingBeforeStarting() {
        var outcome = SubAgentExecutor.Outcome(
            succeeded: false, summary: "", toolCallsMade: [], filesChanged: [], refusedActions: [],
            worktreePath: nil, branch: nil, iterations: 1,
            stoppedBecause: "the model call failed: Could not connect to the server.", durationMs: 1
        )
        XCTAssertTrue(SubAgentExecutor.failedBeforeStarting(outcome))
        outcome.toolCallsMade = ["glob"]
        XCTAssertFalse(SubAgentExecutor.failedBeforeStarting(outcome), "work was done; retrying would repeat it")
        outcome.toolCallsMade = []
        outcome.stoppedBecause = "ran out of time after 600s"
        XCTAssertFalse(SubAgentExecutor.failedBeforeStarting(outcome))
    }

    func testWriteTargetsAreReadFromEitherAlias() {
        XCTAssertEqual(SubAgentExecutor.writeTarget(toolName: "write_file", argumentsJson: #"{"filepath":"/w/r.md","content":""}"#), "/w/r.md")
        XCTAssertNil(SubAgentExecutor.writeTarget(toolName: "file_read", argumentsJson: #"{"path":"/w/r.md"}"#))
    }

    // MARK: - Build environment

    /// `xcode-select` on the Command Line Tools with Xcode installed failed every Xcode build with
    /// "requires Xcode, but active developer directory … is a command line tools instance".
    func testBuildsUseXcodeWhenTheToolsAreSelected() {
        let developer = "/Applications/Xcode.app/Contents/Developer"
        func locator(selected: String?, environment: [String: String] = [:]) -> ExecutableLocator {
            ExecutableLocator(
                environment: environment, home: "/Users/test",
                isExecutable: { $0 == developer + "/usr/bin/xcodebuild" },
                fileExists: { _ in false },
                listDirectory: { $0 == "/Applications" ? ["Xcode.app", "Safari.app"] : [] },
                selectedDeveloperDirectory: { selected }
            )
        }
        XCTAssertEqual(locator(selected: "/Library/Developer/CommandLineTools").xcodeDeveloperDirectoryOverride(), developer)
        XCTAssertNil(locator(selected: developer).xcodeDeveloperDirectoryOverride(), "already on Xcode")
        XCTAssertNil(locator(selected: nil, environment: ["DEVELOPER_DIR": "/x"]).xcodeDeveloperDirectoryOverride(), "an explicit choice wins")
    }

    func testAFailureFromTheMachineIsNotReportedAsZeroErrors() {
        let summary = BuildDiagnostics.summarize(
            command: "xcodebuild build", exitCode: 1,
            output: "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance"
        )
        XCTAssertFalse(summary.contains("0 error(s)"), summary)
        XCTAssertTrue(summary.contains("sudo xcode-select -s"), summary)
    }

    // MARK: - Session bookkeeping

    func testActivityStampsTheSessionAndTotalsItsTokens() {
        var session = Session(createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        session.messages = [
            ChatMessage(sessionId: "s", role: .assistant, content: "a", promptTokens: 100, completionTokens: 10),
            ChatMessage(sessionId: "s", role: .assistant, content: "b", promptTokens: 200, completionTokens: 20),
        ]
        session.recordActivity(at: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(session.totalPromptTokens, 300)
        XCTAssertEqual(session.totalCompletionTokens, 30)
    }

    // MARK: - Re-reading

    func testAnUnchangedFileStillInContextIsNotReadAgain() throws {
        try "echo hi\n".write(toFile: root + "/a.sh", atomically: true, encoding: .utf8)
        let args = #"{"path":"a.sh"}"#
        let path = AgentRunner.readTarget(argumentsJson: args, workspaceRoot: root)!
        let log = [AgentRunner.callSignature("file_read", args):
            AgentRunner.RecordedRead(callId: "r1", modified: AgentRunner.modificationDate(path), step: 2)]
        let transcript = [ChatMessage(id: "r1", sessionId: "s", role: .tool, content: "1\techo hi")]

        let note = AgentRunner.unchangedReadNote(toolName: "read_file", argumentsJson: #"{"filepath":"a.sh"}"#,
                                                 workspaceRoot: root, log: log, transcript: transcript)
        XCTAssertTrue(note?.contains("step 2") ?? false, note ?? "nil")

        // Folded out of context: read it again.
        let folded = [ChatMessage(id: "r1", sessionId: "s", role: .tool, content: "[Earlier tool result compacted] 1 echo hi…")]
        XCTAssertNil(AgentRunner.unchangedReadNote(toolName: "file_read", argumentsJson: args, workspaceRoot: root, log: log, transcript: folded))

        // Changed on disk since: read it again.
        try "echo bye\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
        XCTAssertNil(AgentRunner.unchangedReadNote(toolName: "file_read", argumentsJson: args, workspaceRoot: root, log: log, transcript: transcript))
    }

    // MARK: - History across turns

    private func turn() -> (session: Session, context: [ChatMessage]) {
        let user = ChatMessage(id: "u1", sessionId: "s", role: .user, content: "fix it")
        let reply = ChatMessage(id: "a1", sessionId: "s", role: .assistant, content: "Done.")
        let call = ToolCallInfo(id: "c1", toolName: "file_read", argumentsJson: #"{"path":"a"}"#)
        let context = [
            user,
            ChatMessage(sessionId: "s", role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(id: "c1", sessionId: "s", role: .tool, content: "contents of a"),
            ChatMessage(id: "a1", sessionId: "s", role: .assistant, content: "Done."),
        ]
        var session = Session(messages: [user, reply])
        session.modelContext = ModelContextSnapshot(coveredMessageIds: ["u1", "a1"], messages: context)
        return (session, context)
    }

    /// The next message continues the transcript the model saw, tool results included, instead
    /// of a history the local cache has never seen.
    func testTheNextTurnContinuesTheModelsOwnTranscript() {
        var (session, context) = turn()
        let next = ChatMessage(id: "u2", sessionId: "s", role: .user, content: "and the bell")
        session.messages.append(next)
        XCTAssertEqual(session.modelHistory(), context + [next])
    }

    func testAnEditedOrShortenedHistoryFallsBackToThePlainMessages() {
        var (session, _) = turn()
        session.messages[0].content = "fix something else"
        XCTAssertEqual(session.modelHistory(), session.messages)

        var (forked, _) = turn()
        forked.messages.removeLast()
        XCTAssertEqual(forked.modelHistory(), forked.messages)
    }

    func testTheSnapshotSurvivesASaveAndOldSessionsStillLoad() throws {
        let (session, _) = turn()
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.modelContext, session.modelContext)

        var plain = session
        plain.modelContext = nil
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(plain)).modelContext)
    }

    func testSlashCommandsDoNotNameASession() {
        XCTAssertFalse(Session.isTitleCandidate("/i-have-adhd"))
        XCTAssertTrue(Session.isTitleCandidate("Do a deep dive on this project"))
    }
}
