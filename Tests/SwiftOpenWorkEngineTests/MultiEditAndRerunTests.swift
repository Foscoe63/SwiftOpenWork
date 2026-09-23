import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Four related changes to one file cost four round trips today, and if the third fails the file
/// is left matching neither the before nor the intended after. Half-applied is the worst available
/// outcome, so the whole result is computed before anything is written.
final class MultiEditTests: XCTestCase {

    private let source = """
    let a = 1
    let b = 2
    let c = 3
    """

    func testEditsApplyInOrder() throws {
        let result = MultiEdit.apply([
            .init(oldString: "let a = 1", newString: "let a = 10"),
            .init(oldString: "let c = 3", newString: "let c = 30")
        ], to: source)

        let applied = try XCTUnwrap(try? result.get())
        XCTAssertEqual(applied.contents, "let a = 10\nlet b = 2\nlet c = 30")
        XCTAssertEqual(applied.replacements, [1, 1])
    }

    /// The point of the tool: a later edit can target text an earlier one introduced.
    func testALaterEditSeesAnEarlierEditsResult() throws {
        let result = MultiEdit.apply([
            .init(oldString: "let b = 2", newString: "let beta = 2"),
            .init(oldString: "let beta = 2", newString: "let beta = 22")
        ], to: source)
        let applied = try XCTUnwrap(try? result.get())
        XCTAssertTrue(applied.contents.contains("let beta = 22"))
    }

    func testOneFailedEditDiscardsThemAll() {
        let result = MultiEdit.apply([
            .init(oldString: "let a = 1", newString: "let a = 10"),
            .init(oldString: "let zzz = 9", newString: "never")
        ], to: source)

        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        guard case .notFound(let index, let old, _) = failure else { return XCTFail("expected notFound") }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(old, "let zzz = 9")
        XCTAssertTrue(failure.message.contains("the file is unchanged"),
                      "a model told only that edit 2 failed would have to guess whether edit 1 landed")
    }

    func testAmbiguousEditIsRefusedRatherThanGuessed() {
        let result = MultiEdit.apply([.init(oldString: "let", newString: "var")], to: source)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure, .ambiguous(index: 0, count: 3))
    }

    func testReplaceAllTakesEveryOccurrence() throws {
        let result = MultiEdit.apply([.init(oldString: "let", newString: "var", replaceAll: true)], to: source)
        let applied = try XCTUnwrap(try? result.get())
        XCTAssertEqual(applied.contents, "var a = 1\nvar b = 2\nvar c = 3")
        XCTAssertEqual(applied.total, 3)
    }

    func testEmptyEditListIsRefused() {
        guard case .failure(let failure) = MultiEdit.apply([], to: source) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(failure, .noEdits)
    }

    func testEmptyOldStringIsRefused() {
        let result = MultiEdit.apply([.init(oldString: "", newString: "x")], to: source)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure, .emptyOldString(index: 0))
    }

    // MARK: - Argument shapes local models actually emit

    func testParsesAListOfEdits() {
        let dict: [String: Any] = ["edits": [
            ["old_string": "a", "new_string": "b"],
            ["oldString": "c", "newString": "d", "replaceAll": true]
        ]]
        XCTAssertEqual(MultiEdit.parseEdits(from: dict), [
            .init(oldString: "a", newString: "b"),
            .init(oldString: "c", newString: "d", replaceAll: true)
        ])
    }

    func testParsesASingleEditNotWrappedInAList() {
        let dict: [String: Any] = ["edits": ["old_string": "a", "new_string": "b"]]
        XCTAssertEqual(MultiEdit.parseEdits(from: dict), [.init(oldString: "a", newString: "b")])
    }

    func testParsesEditsDeliveredAsAJSONString() {
        let dict: [String: Any] = ["edits": #"[{"old_string":"a","new_string":"b"}]"#]
        XCTAssertEqual(MultiEdit.parseEdits(from: dict), [.init(oldString: "a", newString: "b")])
    }

    /// A misread edit list writes the wrong thing to disk, so a malformed one is rejected.
    func testRejectsEditsMissingAField() {
        XCTAssertNil(MultiEdit.parseEdits(from: ["edits": [["old_string": "a"]]]))
        XCTAssertNil(MultiEdit.parseEdits(from: ["edits": "not json"]))
        XCTAssertNil(MultiEdit.parseEdits(from: [:]))
    }
}

/// Re-running one test after fixing it is the tight loop. Reconstructing a runner-specific filter
/// flag from diagnostic text is where it goes wrong quietly: a filter matching nothing exits zero.
final class RerunFailingTestsTests: XCTestCase {

    func testExtractsXCTestIdentities() {
        let output = """
        Test Case '-[SwiftOpenWorkTests.MultiEditTests testEditsApplyInOrder]' started.
        /repo/Tests/MultiEditTests.swift:12: error: -[SwiftOpenWorkTests.MultiEditTests testEditsApplyInOrder] : XCTAssertEqual failed
        Test Case '-[SwiftOpenWorkTests.MultiEditTests testEditsApplyInOrder]' failed (0.01 seconds).
        """
        XCTAssertEqual(
            BuildDiagnostics.failedTests(in: output),
            [.init(suite: "SwiftOpenWorkTests.MultiEditTests", name: "testEditsApplyInOrder")],
            "the same test named on three lines is one failure"
        )
    }

    func testExtractsGoFailures() {
        let output = "--- FAIL: TestParse (0.00s)\n--- FAIL: TestRender (0.01s)\nFAIL"
        XCTAssertEqual(
            BuildDiagnostics.failedTests(in: output).map(\.name),
            ["TestParse", "TestRender"]
        )
    }

    func testExtractsPytestFailures() {
        let output = "FAILED tests/test_api.py::test_login - assert 1 == 2\n1 failed"
        XCTAssertEqual(
            BuildDiagnostics.failedTests(in: output).map(\.name),
            ["tests/test_api.py::test_login"]
        )
    }

    func testAPassingRunNamesNoFailures() {
        XCTAssertTrue(BuildDiagnostics.failedTests(in: "Executed 253 tests, with 0 failures").isEmpty)
    }

    func testSwiftPMRerunFiltersEachFailure() {
        let command = BuildDiagnostics.rerunCommand(
            baseCommand: "swift test",
            failures: [.init(suite: "Pkg.SuiteA", name: "testOne"), .init(suite: "Pkg.SuiteB", name: "testTwo")]
        )
        // The dot in a namespaced suite is a regex wildcard if left unescaped.
        XCTAssertEqual(command, #"swift test --filter 'Pkg\.SuiteA/testOne' --filter 'Pkg\.SuiteB/testTwo'"#)
    }

    func testGoRerunAnchorsTheNames() {
        XCTAssertEqual(
            BuildDiagnostics.rerunCommand(baseCommand: "go test ./...", failures: [.init(name: "TestParse")]),
            "go test ./... -run '^(TestParse)$'"
        )
    }

    func testXcodebuildRerunScopesToTargetClassAndMethod() {
        let command = BuildDiagnostics.rerunCommand(
            baseCommand: "xcodebuild -project Demo.xcodeproj -scheme Demo test",
            failures: [
                .init(suite: "DemoTests.SuiteA", name: "testOne"),
                .init(suite: "DemoTests.SuiteB", name: "testTwo"),
            ]
        )
        XCTAssertEqual(
            command,
            "xcodebuild -project Demo.xcodeproj -scheme Demo test"
                + " -only-testing:DemoTests/SuiteA/testOne -only-testing:DemoTests/SuiteB/testTwo"
        )
    }

    /// Without a module-qualified suite there is no test target to scope to, and an unscoped
    /// -only-testing matches nothing — which exits zero and reads as a pass.
    func testXcodebuildRerunRefusesUnqualifiedSuites() {
        XCTAssertNil(BuildDiagnostics.rerunCommand(
            baseCommand: "xcodebuild -scheme Demo test",
            failures: [.init(name: "testOne")]
        ))
        XCTAssertNil(BuildDiagnostics.rerunCommand(
            baseCommand: "xcodebuild -scheme Demo test",
            failures: [.init(suite: "SuiteA", name: "testOne")]
        ))
    }

    func testAnAlreadyScopedXcodebuildCommandIsLeftAlone() {
        XCTAssertNil(BuildDiagnostics.rerunCommand(
            baseCommand: "xcodebuild -scheme Demo test -only-testing:DemoTests/SuiteA",
            failures: [.init(suite: "DemoTests.SuiteA", name: "testOne")]
        ))
    }

    /// A filter flag an unknown runner ignores would run everything while claiming otherwise.
    func testUnknownRunnerIsNotNarrowed() {
        XCTAssertNil(BuildDiagnostics.rerunCommand(baseCommand: "npm test", failures: [.init(name: "a")]))
    }

    func testAnAlreadyNarrowedCommandIsLeftAlone() {
        XCTAssertNil(BuildDiagnostics.rerunCommand(
            baseCommand: "swift test --filter SomeTests",
            failures: [.init(suite: "S", name: "t")]
        ))
    }

    func testNoFailuresMeansNoNarrowedCommand() {
        XCTAssertNil(BuildDiagnostics.rerunCommand(baseCommand: "swift test", failures: []))
    }

    func testSummaryNamesFailingTestsSoTheyCanBeReRun() {
        let summary = BuildDiagnostics.summarize(
            command: "swift test",
            exitCode: 1,
            output: "/repo/T.swift:3: error: -[Suite testThing] : XCTAssertTrue failed"
        )
        XCTAssertTrue(summary.contains("Failing tests: Suite/testThing"))
        XCTAssertTrue(summary.contains("only_failing"))
    }

    // MARK: - What is remembered

    func testAGreenRunClearsTheRememberedFailures() async {
        let store = LastTestFailures()
        await store.record([.init(suite: "S", name: "t")], for: "/repo")
        var remembered = await store.failures(for: "/repo")
        XCTAssertEqual(remembered.count, 1)

        await store.record([], for: "/repo")
        remembered = await store.failures(for: "/repo")
        XCTAssertTrue(remembered.isEmpty,
                      "otherwise 'only failing' keeps re-running tests that already pass and reports success")
    }

    func testFailuresAreRememberedPerWorkspace() async {
        let store = LastTestFailures()
        await store.record([.init(name: "TestA")], for: "/repo-one")
        let other = await store.failures(for: "/repo-two")
        XCTAssertTrue(other.isEmpty)
    }
}

/// multi_edit through the real tool path: the file on disk is what matters.
final class MultiEditToolTests: XCTestCase {

    private var root = ""
    private var workspace: Workspace!
    private let agent = Agent(name: "Test")

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "multiedit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Test", folderPath: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func run(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return await ToolExecutionEngine.shared.execute(
            toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent
        )
    }

    func testAppliesEveryEditToTheFile() async throws {
        let file = root + "/a.swift"
        try "let a = 1\nlet b = 2".write(toFile: file, atomically: true, encoding: .utf8)

        let result = await run("multi_edit", [
            "path": "a.swift",
            "edits": [
                ["old_string": "let a = 1", "new_string": "let a = 10"],
                ["old_string": "let b = 2", "new_string": "let b = 20"]
            ]
        ])

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "let a = 10\nlet b = 20")
    }

    /// The property the tool exists for: a failure leaves nothing half-written.
    func testAFailedEditLeavesTheFileUntouched() async throws {
        let file = root + "/a.swift"
        let original = "let a = 1\nlet b = 2"
        try original.write(toFile: file, atomically: true, encoding: .utf8)

        let result = await run("multi_edit", [
            "path": "a.swift",
            "edits": [
                ["old_string": "let a = 1", "new_string": "let a = 10"],
                ["old_string": "nonexistent", "new_string": "x"]
            ]
        ])

        XCTAssertFalse(result.success)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), original,
                       "the first edit must not have landed")
    }

    func testEditsAreUndoableLikeAnyOtherWrite() async throws {
        let file = root + "/a.swift"
        try "let a = 1".write(toFile: file, atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()

        _ = await run("multi_edit", [
            "path": "a.swift",
            "edits": [["old_string": "let a = 1", "new_string": "let a = 99"]]
        ])
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "let a = 99")

        _ = await run("revert_changes", [:])
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "let a = 1")
    }

    /// It writes files, so it must be gated exactly like the tools it replaces — otherwise adding
    /// it would be a way around both the approval prompt and plan mode.
    @MainActor
    func testItIsGatedLikeEveryOtherWritingTool() {
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "multi_edit", settings: AppSettings()))

        let tools = [Tool(id: "multi_edit", name: "multi_edit", displayName: "Multi Edit", description: "", category: .files)]
        let planTools = AgentRunner.filterToolsForPlanMode(tools).map(\.name)
        XCTAssertFalse(planTools.contains("multi_edit"),
                       "plan mode must not leave a writing tool available")
    }

    // MARK: - cargo

    func testCargoFailuresAreParsedFromLibtestResultLines() {
        let output = """
        running 3 tests
        test math::adds ... ok
        test math::subtracts ... FAILED
        test parser::rejects_empty ... FAILED
        test src/lib.rs - math::adds (line 12) ... FAILED

        failures:
            math::subtracts
        """
        XCTAssertEqual(
            BuildDiagnostics.failedTests(in: output).map(\.name),
            ["math::subtracts", "parser::rejects_empty"],
            "doc-test lines name a file and line, which --exact cannot select"
        )
    }

    func testCargoRerunUsesExactFiltersAfterTheSeparator() {
        let command = BuildDiagnostics.rerunCommand(
            baseCommand: "cargo test",
            failures: [.init(name: "math::subtracts"), .init(name: "parser::rejects_empty")]
        )
        XCTAssertEqual(command, "cargo test -- --exact 'math::subtracts' 'parser::rejects_empty'")
    }

    func testCargoWithItsOwnLibtestArgumentsIsNotNarrowed() {
        XCTAssertNil(BuildDiagnostics.rerunCommand(baseCommand: "cargo test -- --nocapture", failures: [.init(name: "a")]))
    }
    func testWhitespaceDriftStillMatchesUniquely() throws {
        let file = "struct A {\n    func f() {\n        let x = 1\n    }\n}\n"
        let result = MultiEdit.apply([
            .init(oldString: "\nfunc f() {\n    let x = 1\n}\n", newString: "\nfunc f() {\n    let x = 2\n}\n")
        ], to: file)
        let applied = try XCTUnwrap(try? result.get())
        XCTAssertEqual(applied.contents, "struct A {\n    func f() {\n        let x = 2\n    }\n}\n")
    }
}
