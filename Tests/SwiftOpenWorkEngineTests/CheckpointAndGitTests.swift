import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Undo, change reporting, git reads, and per-repo instructions.
final class CheckpointAndGitTests: XCTestCase {

    private var root = ""
    private var workspace: Workspace!
    private let agent = Agent(name: "Test")

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ckpt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Test", folderPath: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func run(_ tool: String, _ args: [String: Any] = [:]) async -> ToolExecutionResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return await ToolExecutionEngine.shared.execute(
            toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent
        )
    }

    private func path(_ name: String) -> String { root + "/" + name }

    // MARK: - Adding to a file without replacing it

    func testAppendKeepsTheExistingText() async throws {
        try "one\ntwo\n".write(toFile: path("log.md"), atomically: true, encoding: .utf8)
        let result = await run("file_write", ["path": "log.md", "content": "three\n", "append": true])
        XCTAssertTrue(result.success)
        XCTAssertEqual(try String(contentsOfFile: path("log.md"), encoding: .utf8), "one\ntwo\nthree\n")
    }

    func testBeforeInsertsAboveTheFooterAndKeepsEverythingElse() async throws {
        try "# Map\n\n## A\ntext\n\n*End*\n".write(toFile: path("map.md"), atomically: true, encoding: .utf8)
        let result = await run("file_write", ["path": "map.md", "content": "## B\nmore\n", "before": "*End*"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(try String(contentsOfFile: path("map.md"), encoding: .utf8), "# Map\n\n## A\ntext\n\n## B\nmore\n\n*End*\n")
    }

    func testBeforeWithAMissingLineWritesNothing() async throws {
        try "alpha\n".write(toFile: path("x.md"), atomically: true, encoding: .utf8)
        let result = await run("file_write", ["path": "x.md", "content": "new", "before": "*End*"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(try String(contentsOfFile: path("x.md"), encoding: .utf8), "alpha\n")
    }

    // MARK: - Checkpoints

    func testRevertRestoresAnEditedFile() async throws {
        try "original".write(toFile: path("a.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()

        _ = await run("file_write", ["path": "a.txt", "content": "changed"])
        XCTAssertEqual(try String(contentsOfFile: path("a.txt"), encoding: .utf8), "changed")

        let result = await run("revert_changes")
        XCTAssertTrue(result.success)
        XCTAssertEqual(try String(contentsOfFile: path("a.txt"), encoding: .utf8), "original")
    }

    /// A file the turn created has no prior contents, so reverting must delete it.
    func testRevertDeletesAFileTheTurnCreated() async throws {
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "new.txt", "content": "hello"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("new.txt")))

        _ = await run("revert_changes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("new.txt")))
    }

    func testRevertRestoresADeletedFile() async throws {
        try "keep me".write(toFile: path("doomed.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()

        _ = await run("file_delete", ["path": "doomed.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("doomed.txt")))

        _ = await run("revert_changes")
        XCTAssertEqual(try String(contentsOfFile: path("doomed.txt"), encoding: .utf8), "keep me")
    }

    /// The reference point is the start of the turn, not the state between two edits.
    func testRevertUndoesAllEditsBackToTurnStart() async throws {
        try "v0".write(toFile: path("a.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()

        _ = await run("file_write", ["path": "a.txt", "content": "v1"])
        _ = await run("file_write", ["path": "a.txt", "content": "v2"])
        _ = await run("revert_changes")

        XCTAssertEqual(try String(contentsOfFile: path("a.txt"), encoding: .utf8), "v0")
    }

    func testEditFileIsCheckpointed() async throws {
        try "let a = 1\nlet b = 2".write(toFile: path("code.swift"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()

        _ = await run("edit_file", ["path": "code.swift", "old_string": "let a = 1", "new_string": "let a = 99"])
        XCTAssertTrue(try String(contentsOfFile: path("code.swift"), encoding: .utf8).contains("99"))

        _ = await run("revert_changes")
        XCTAssertFalse(try String(contentsOfFile: path("code.swift"), encoding: .utf8).contains("99"))
    }

    /// A new turn must not be able to roll back the previous one.
    func testBeginTurnDiscardsEarlierHistory() async throws {
        try "original".write(toFile: path("a.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "a.txt", "content": "turn one"])

        await FileCheckpointStore.shared.beginTurn()
        let result = await run("revert_changes")

        XCTAssertFalse(result.success, "a fresh turn has nothing to revert")
        XCTAssertEqual(try String(contentsOfFile: path("a.txt"), encoding: .utf8), "turn one")
    }

    func testChangedFilesReportsCreatesAndEdits() async throws {
        try "before".write(toFile: path("edited.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "edited.txt", "content": "after"])
        _ = await run("file_write", ["path": "fresh.txt", "content": "new"])

        let result = await run("changed_files")
        XCTAssertTrue(result.output.contains("edited.txt"))
        XCTAssertTrue(result.output.contains("fresh.txt"))
        XCTAssertTrue(result.output.contains("modified"))
        XCTAssertTrue(result.output.contains("added"))
    }

    func testRevertWithNothingRecordedIsAnError() async throws {
        await FileCheckpointStore.shared.beginTurn()
        let result = await run("revert_changes")
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("Nothing to revert"))
    }

    /// Writing a file and deleting it again within one turn leaves nothing to report.
    func testCreateThenDeleteReportsNoChange() async throws {
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "temp.txt", "content": "x"])
        _ = await run("file_delete", ["path": "temp.txt"])

        let summary = await FileCheckpointStore.shared.summary()
        XCTAssertTrue(summary.isEmpty)
    }

    // MARK: - Git

    func testGitToolsReportNonRepositoryClearly() async {
        let status = await run("git_status")
        XCTAssertFalse(status.success)
        XCTAssertTrue(status.output.contains("not a git repository"))
    }

    func testGitStatusAndDiffOnARealRepository() async throws {
        // A throwaway repo keeps this independent of the checkout the tests run in.
        for args in [["init", "-q"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"]] {
            _ = GitTools.run(args, in: root)
        }
        try "one\n".write(toFile: path("tracked.txt"), atomically: true, encoding: .utf8)
        _ = GitTools.run(["add", "."], in: root)
        _ = GitTools.run(["commit", "-qm", "initial"], in: root)

        let clean = await run("git_status")
        XCTAssertTrue(clean.success)
        XCTAssertTrue(clean.output.contains("clean"), clean.output)

        try "one\ntwo\n".write(toFile: path("tracked.txt"), atomically: true, encoding: .utf8)
        let dirty = await run("git_status")
        XCTAssertTrue(dirty.output.contains("modified"))

        let diff = await run("git_diff")
        XCTAssertTrue(diff.output.contains("+two"), diff.output)

        let log = await run("git_log")
        XCTAssertTrue(log.output.contains("initial"))
    }

    func testPorcelainCodeDescriptions() {
        XCTAssertEqual(GitTools.describe("??").trimmingCharacters(in: .whitespaces), "untracked")
        XCTAssertEqual(GitTools.describe(" M").trimmingCharacters(in: .whitespaces), "modified")
        XCTAssertEqual(GitTools.describe("A ").trimmingCharacters(in: .whitespaces), "added")
        XCTAssertEqual(GitTools.describe(" D").trimmingCharacters(in: .whitespaces), "deleted")
    }

    // MARK: - Project instructions

    func testInstructionsLoadFromRepository() throws {
        try "Always run swift test.".write(toFile: path("AGENTS.md"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(folderPath: root)
        XCTAssertEqual(loaded?.name, "AGENTS.md")
        XCTAssertTrue(ProjectInstructions.promptBlock(loaded).contains("Always run swift test."))
    }

    func testMostSpecificInstructionFileWins() throws {
        try "openwork".write(toFile: path("OPENWORK.md"), atomically: true, encoding: .utf8)
        try "agents".write(toFile: path("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructions.load(folderPath: root)?.name, "OPENWORK.md")
    }

    func testEmptyInstructionFileIsIgnored() throws {
        try "   \n".write(toFile: path("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(ProjectInstructions.load(folderPath: root))
    }

    func testOversizedInstructionsAreClipped() throws {
        let huge = String(repeating: "a", count: ProjectInstructions.maxCharacters + 500)
        try huge.write(toFile: path("AGENTS.md"), atomically: true, encoding: .utf8)
        let loaded = ProjectInstructions.load(folderPath: root)
        XCTAssertEqual(loaded?.clipped, true)
        XCTAssertEqual(loaded?.content.count, ProjectInstructions.maxCharacters)
    }

    func testNoInstructionsRendersNothing() {
        XCTAssertTrue(ProjectInstructions.promptBlock(nil).isEmpty)
    }
}

/// Backing data for the turn-change review UI.
final class TurnChangeDataTests: XCTestCase {

    private var root = ""
    private var workspace: Workspace!
    private let agent = Agent(name: "Test")

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "changes-\(UUID().uuidString)"
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

    private func path(_ n: String) -> String { root + "/" + n }

    func testChangesCarryBothSidesForADiff() async throws {
        try "before".write(toFile: path("m.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "m.txt", "content": "after"])

        let changes = await FileCheckpointStore.shared.changes()
        let change = try XCTUnwrap(changes.first(where: { $0.path.hasSuffix("m.txt") }))
        XCTAssertEqual(change.kind, .modified)
        XCTAssertEqual(change.before, "before")
        XCTAssertEqual(change.after, "after")
    }

    func testCreatedFileHasNoBeforeSide() async throws {
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "n.txt", "content": "fresh"])

        let all = await FileCheckpointStore.shared.changes()
        let change = try XCTUnwrap(all.first)
        XCTAssertEqual(change.kind, .created)
        XCTAssertNil(change.before)
        XCTAssertEqual(change.after, "fresh")
    }

    func testDeletedFileHasNoAfterSide() async throws {
        try "gone".write(toFile: path("d.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_delete", ["path": "d.txt"])

        let all = await FileCheckpointStore.shared.changes()
        let change = try XCTUnwrap(all.first)
        XCTAssertEqual(change.kind, .deleted)
        XCTAssertEqual(change.before, "gone")
        XCTAssertNil(change.after)
    }

    /// Reverting one file must leave the rest of the turn in place.
    func testSingleFileRevertIsIsolated() async throws {
        try "a0".write(toFile: path("a.txt"), atomically: true, encoding: .utf8)
        try "b0".write(toFile: path("b.txt"), atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn()
        _ = await run("file_write", ["path": "a.txt", "content": "a1"])
        _ = await run("file_write", ["path": "b.txt", "content": "b1"])

        let reverted = await FileCheckpointStore.shared.revert(path: path("a.txt"))
        XCTAssertTrue(reverted)
        XCTAssertEqual(try String(contentsOfFile: path("a.txt"), encoding: .utf8), "a0")
        XCTAssertEqual(try String(contentsOfFile: path("b.txt"), encoding: .utf8), "b1")

        let remaining = await FileCheckpointStore.shared.changes()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].path.hasSuffix("b.txt"))
    }

    func testRevertingAnUntrackedPathReportsFailure() async {
        await FileCheckpointStore.shared.beginTurn()
        let ok = await FileCheckpointStore.shared.revert(path: path("never-touched.txt"))
        XCTAssertFalse(ok)
    }

    func testChangesAreSortedByPath() async throws {
        await FileCheckpointStore.shared.beginTurn()
        for name in ["z.txt", "a.txt", "m.txt"] {
            _ = await run("file_write", ["path": name, "content": "x"])
        }
        let paths = await FileCheckpointStore.shared.changes().map(\.path)
        XCTAssertEqual(paths, paths.sorted())
    }
}
