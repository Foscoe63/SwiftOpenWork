import XCTest
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

/// Git was read-only here on purpose. A worktree is what makes committing safe rather than a
/// weakening of that rule: history added on a branch of its own cannot rewrite anything the user
/// wrote, which is exactly why session-wide undo was rejected and this is not the same thing.
final class AgentWorktreeTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("owt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await AgentWorktree.git(["init", "-q", "-b", "main"], in: repo)
        try await AgentWorktree.git(["config", "user.email", "t@example.com"], in: repo)
        try await AgentWorktree.git(["config", "user.name", "Test"], in: repo)
        try "seed\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try await AgentWorktree.git(["add", "-A"], in: repo)
        try await AgentWorktree.git(["commit", "-q", "-m", "seed"], in: repo)
    }

    override func tearDownWithError() throws {
        let container = AgentWorktree.container(for: repo)
        try? FileManager.default.removeItem(at: container)
        try? FileManager.default.removeItem(at: repo)
    }

    /// `XCTAssertThrowsError` predates async, so awaiting calls need their own spelling.
    private func expectFailure<T>(
        _ operation: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ inspect: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected an error but the call succeeded", file: file, line: line)
        } catch {
            inspect(error)
        }
    }

    /// A worktree started from the last commit, so a sub-agent edited files as they were before
    /// the user's uncommitted changes — 56 of them in the run that showed it.
    func testASeededWorktreeStartsFromTheUsersUncommittedState() async throws {
        try "seed\nwork in progress\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("new"), withIntermediateDirectories: true)
        try "brand new\n".write(to: repo.appendingPathComponent("new/file.txt"), atomically: true, encoding: .utf8)

        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "seeded")
        let seed = await AgentWorktree.seedWithUncommittedChanges(worktree: info, workspacePath: repo.path)
        let tree = URL(fileURLWithPath: info.path)

        XCTAssertTrue(seed.copiedChanges)
        XCTAssertNil(seed.problem)
        XCTAssertNotEqual(seed.head, info.head, "the snapshot is its own commit")
        XCTAssertEqual(try String(contentsOf: tree.appendingPathComponent("seed.txt"), encoding: .utf8), "seed\nwork in progress\n")
        XCTAssertEqual(try String(contentsOf: tree.appendingPathComponent("new/file.txt"), encoding: .utf8), "brand new\n")
        let status = try await AgentWorktree.git(["status", "--porcelain"], in: tree)
        XCTAssertEqual(status, "", "the user's changes must not be reported as the sub-agent's")

        // The user's own checkout is untouched.
        let own = try await AgentWorktree.git(["status", "--porcelain"], in: repo)
        XCTAssertTrue(own.contains("seed.txt"))
        let log = try await AgentWorktree.git(["log", "--oneline"], in: repo)
        XCTAssertEqual(log.split(separator: "\n").count, 1)
    }

    func testACleanCheckoutIsLeftAtItsCommit() async throws {
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "clean")
        let seed = await AgentWorktree.seedWithUncommittedChanges(worktree: info, workspacePath: repo.path)
        XCTAssertFalse(seed.copiedChanges)
        XCTAssertEqual(seed.head, info.head)
    }

    /// Git subprocesses must never block the caller's thread: a `waitUntilExit()` on the main
    /// thread both freezes the UI and spins the run loop, which re-enters unrelated work.
    func testGitRunsOffTheCallersThread() async throws {
        let ranOnMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AgentWorktree.gitQueueForTesting.async {
                continuation.resume(returning: Thread.isMainThread)
            }
        }
        XCTAssertFalse(ranOnMain, "git must not run on the main thread")
    }

    /// The whole safety argument in one assertion: the user's own checkout is not committable.
    func testCommittingOnTheUsersOwnCheckoutIsRefused() async throws {
        try "dirty\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        await expectFailure(try await AgentWorktree.commit(worktreePath: repo.path, message: "nope")) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("committing stays yours"), "got: \(text)")
        }
        // And it really did not commit.
        let log = try await AgentWorktree.git(["log", "--oneline"], in: repo)
        XCTAssertEqual(log.split(separator: "\n").count, 1, "the user's history must be untouched")
    }

    func testCreateGivesAnIsolatedTreeOnItsOwnBranch() async throws {
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "Dark Mode Fix!")
        XCTAssertEqual(info.branch, "swiftopenwork/dark-mode-fix")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))
        // Beside the repo, never inside it, or the parent's own status and file search see it.
        XCTAssertFalse(info.path.hasPrefix(repo.path + "/"))
        let isOurs = await AgentWorktree.isAgentWorktree(info.path)
        XCTAssertTrue(isOurs)
    }

    func testWorkInAWorktreeCommitsThereAndLeavesMainAlone() async throws {
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "feature")
        let file = URL(fileURLWithPath: info.path).appendingPathComponent("added.txt")
        try "agent wrote this\n".write(to: file, atomically: true, encoding: .utf8)

        let output = try await AgentWorktree.commit(worktreePath: info.path, message: "Add a file")
        XCTAssertTrue(output.contains("swiftopenwork/feature"), "got: \(output)")

        // The worktree advanced...
        let wtLog = try await AgentWorktree.git(["log", "--oneline"], in: URL(fileURLWithPath: info.path))
        XCTAssertEqual(wtLog.split(separator: "\n").count, 2)

        // ...and the user's branch did not.
        let mainLog = try await AgentWorktree.git(["log", "--oneline", "main"], in: repo)
        XCTAssertEqual(mainLog.split(separator: "\n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("added.txt").path))
    }

    func testCommittingNothingIsNotReportedAsSuccess() async throws {
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "empty")
        await expectFailure(try await AgentWorktree.commit(worktreePath: info.path, message: "nothing"))
    }

    /// Removing a worktree is the one irreversible action here, so a dirty one needs saying twice.
    func testRemovingADirtyWorktreeNeedsForce() async throws {
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "dirty")
        try "uncommitted\n".write(
            to: URL(fileURLWithPath: info.path).appendingPathComponent("wip.txt"),
            atomically: true, encoding: .utf8
        )
        await expectFailure(try await AgentWorktree.remove(workspacePath: repo.path, name: "dirty", force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path), "must not have been removed")
        _ = try await AgentWorktree.remove(workspacePath: repo.path, name: "dirty", force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.path))
    }

    func testCreateIsIdempotentSoARetryLandsInTheSamePlace() async throws {
        let first = try await AgentWorktree.create(workspacePath: repo.path, name: "retry")
        let second = try await AgentWorktree.create(workspacePath: repo.path, name: "retry")
        XCTAssertEqual(first.path, second.path)
    }

    func testListOnlyReportsAgentWorktrees() async throws {
        _ = try await AgentWorktree.create(workspacePath: repo.path, name: "one")
        let trees = try await AgentWorktree.list(workspacePath: repo.path)
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(trees.first?.branch, "swiftopenwork/one")
    }

    func testNameSanitisingCannotProduceAnInvalidRef() {
        XCTAssertEqual(AgentWorktree.sanitize("Dark Mode / Fix!!"), "dark-mode-fix")
        XCTAssertEqual(AgentWorktree.sanitize("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(AgentWorktree.sanitize(""), "task")
        XCTAssertEqual(AgentWorktree.sanitize("   "), "task")
    }

    // MARK: - Bringing a branch back

    /// Sub-agent work stranded on branches: the only way back was a shell `git merge`, refused
    /// under the default safety level. `apply` brings in the agent's own changes and nothing else.
    func testApplyBringsInOnlyTheAgentsOwnWorkAndCommitsNothing() async throws {
        try "seed\nwork in progress\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "feature")
        _ = await AgentWorktree.seedWithUncommittedChanges(worktree: info, workspacePath: repo.path)
        // Left uncommitted, as a sub-agent that stopped mid-task would leave it.
        try "agent wrote this\n".write(to: URL(fileURLWithPath: info.path).appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)

        let plan = try await AgentWorktree.planMerge(workspacePath: repo.path, name: "feature")
        XCTAssertEqual(plan.files, ["added.txt"], "the snapshot of the user's own edits is not the agent's work")
        let output = try await AgentWorktree.merge(plan, strategy: .apply)
        XCTAssertTrue(output.contains("Nothing was committed"), output)

        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("added.txt"), encoding: .utf8), "agent wrote this\n")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("seed.txt"), encoding: .utf8), "seed\nwork in progress\n")
        let log = try await AgentWorktree.git(["log", "--oneline", "main"], in: repo)
        XCTAssertEqual(log.split(separator: "\n").count, 1, "committing stays the user's")
    }

    func testAMergeCommitIsRefusedWhenItWouldBringTheUsersPendingEditsBackTwice() async throws {
        try "seed\nwork in progress\n".write(to: repo.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "seeded")
        _ = await AgentWorktree.seedWithUncommittedChanges(worktree: info, workspacePath: repo.path)
        try "x\n".write(to: URL(fileURLWithPath: info.path).appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let plan = try await AgentWorktree.planMerge(workspacePath: repo.path, name: "seeded")
        await expectFailure(try await AgentWorktree.merge(plan, strategy: .merge)) { error in
            XCTAssertTrue(error.localizedDescription.contains("apply"), error.localizedDescription)
        }
    }

    func testAMergeOnACleanCheckoutMakesAMergeCommitByBranch() async throws {
        let info = try await AgentWorktree.create(workspacePath: repo.path, name: "clean-merge")
        try "merged\n".write(to: URL(fileURLWithPath: info.path).appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        let committed = await AgentWorktree.commitAll(in: info.path, message: "Add m")
        XCTAssertTrue(committed)

        let plan = try await AgentWorktree.planMerge(workspacePath: repo.path, name: info.branch)
        _ = try await AgentWorktree.merge(plan, strategy: .merge)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("m.txt").path))
        let log = try await AgentWorktree.git(["log", "--oneline", "main"], in: repo)
        XCTAssertEqual(log.split(separator: "\n").count, 3, "seed, the agent's commit, and the merge")
    }

    func testABranchWithNothingOfItsOwnOrAnUnknownNameIsRefused() async throws {
        _ = try await AgentWorktree.create(workspacePath: repo.path, name: "idle")
        await expectFailure(try await AgentWorktree.planMerge(workspacePath: repo.path, name: "idle"))
        await expectFailure(try await AgentWorktree.planMerge(workspacePath: repo.path, name: "nope")) { error in
            XCTAssertTrue(error.localizedDescription.contains("idle"), "it lists what does exist")
        }
    }
}
