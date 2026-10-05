import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// Sub-agents were theatre. `agent_spawn` built a `SubAgentTask`, returned "Spawned sub-agent […]
/// to execute task", and ran nothing; auto-delegation made one call with `tools: []` and a
/// 512-token ceiling. The inspector drew a Sub-Agent Tree with a Software Engineer, a Deep
/// Research Agent and a Code Review critic above a system that could not open a file.
///
/// These cover the parts that make a real one safe rather than merely capable.
@MainActor
final class SubAgentExecutorTests: XCTestCase {

    private func tool(_ name: String, id: String? = nil) -> Tool {
        Tool(id: id ?? name, name: name, displayName: name, description: "", category: .files,
             parametersJsonSchema: #"{"type":"object","properties":{}}"#)
    }

    private var everyTool: [Tool] {
        ["file_read", "file_write", "grep", "ask_user", "exit_plan_mode", "agent_spawn"].map { tool($0) }
    }

    /// Nobody is watching a sub-agent, so a tool that waits for a person would hang it forever.
    func testAToolThatNeedsAPersonIsNeverAvailable() {
        let settings = AppSettings.default
        let agent = Agent(name: "Coder", canSpawnSubAgents: true)
        let names = Set(SubAgentExecutor.toolSet(for: agent, depth: 1, settings: settings, all: everyTool).map(\.name))
        XCTAssertFalse(names.contains("ask_user"), "a sub-agent asking a question would block forever")
        XCTAssertFalse(names.contains("exit_plan_mode"), "plan mode belongs to the user's turn")
        XCTAssertTrue(names.contains("file_read"))
    }

    /// Writing into the user's checkout is the lead's call, made with the user.
    func testASubAgentCannotMergeIntoTheUsersCheckout() {
        let agent = Agent(name: "Coder", canSpawnSubAgents: true)
        let names = SubAgentExecutor.toolSet(for: agent, depth: 1, settings: .default, all: [tool("worktree_merge"), tool("file_read")]).map(\.name)
        XCTAssertEqual(names, ["file_read"])
    }

    /// Eight steps was too few for anything past a one-file change, and nothing could ask for more.
    func testALeadCanAskForMoreStepsWithinACapAndGetsTimeToMatch() {
        var settings = AppSettings.default
        settings.subAgentStepBudget = 10
        settings.subAgentTimeoutMinutes = 10
        let standard = SubAgentExecutor.budget(requestedSteps: nil, settings: settings)
        XCTAssertEqual(standard.steps, 10)
        XCTAssertEqual(standard.seconds, 600)

        let bigger = SubAgentExecutor.budget(requestedSteps: 20, settings: settings)
        XCTAssertEqual(bigger.steps, 20)
        XCTAssertEqual(bigger.seconds, 1200, "twice the steps, twice the time")

        let greedy = SubAgentExecutor.budget(requestedSteps: 500, settings: settings)
        XCTAssertEqual(greedy.steps, 30, "capped at three times the setting")
        XCTAssertEqual(greedy.seconds, 1800)

        settings.subAgentStepBudget = 40
        XCTAssertEqual(SubAgentExecutor.budget(requestedSteps: 500, settings: settings).steps, SubAgentExecutor.maxRequestableSteps)
        XCTAssertEqual(SubAgentExecutor.budget(requestedSteps: 0, settings: settings).steps, 40)
    }

    /// Reasoning was forced off for every sub-agent.
    func testEffortIsWhatWasAskedElseTheLeadsElseItsOwn() {
        let agent = Agent(name: "Coder", reasoningEffort: .low)
        XCTAssertEqual(SubAgentExecutor.effort(requested: "high", subAgent: agent, parent: .medium), .high)
        XCTAssertEqual(SubAgentExecutor.effort(requested: "none", subAgent: agent, parent: .medium), .off)
        XCTAssertEqual(SubAgentExecutor.effort(requested: "lots", subAgent: agent, parent: .medium), .medium)
        XCTAssertEqual(SubAgentExecutor.effort(requested: nil, subAgent: agent, parent: nil), .low)
    }

    /// Recursion has to stop, or one prompt spawns an unbounded tree.
    func testRecursionStopsAtTheDepthBudget() {
        var settings = AppSettings.default
        settings.allowSubAgentCreation = true
        settings.maxGlobalSubAgentDepth = 2
        let agent = Agent(name: "Coder", canSpawnSubAgents: true)

        let shallow = Set(SubAgentExecutor.toolSet(for: agent, depth: 1, settings: settings, all: everyTool).map(\.name))
        XCTAssertTrue(shallow.contains("agent_spawn"), "inside the budget it may delegate further")

        let atLimit = Set(SubAgentExecutor.toolSet(for: agent, depth: 2, settings: settings, all: everyTool).map(\.name))
        XCTAssertFalse(atLimit.contains("agent_spawn"), "at the budget it must not delegate further")
    }

    /// The global off switch outranks a per-agent yes — the same rule the parent obeys.
    func testTheGlobalSwitchOutranksTheAgent() {
        var settings = AppSettings.default
        settings.allowSubAgentCreation = false
        let agent = Agent(name: "Coder", canSpawnSubAgents: true)
        let names = Set(SubAgentExecutor.toolSet(for: agent, depth: 1, settings: settings, all: everyTool).map(\.name))
        XCTAssertFalse(names.contains("agent_spawn"))
    }

    /// An empty allowlist means "whatever the workspace allows"; a populated one is a real limit.
    func testAPopulatedAllowlistRestrictsAndAnEmptyOneDoesNot() {
        let settings = AppSettings.default
        // Spawning enabled, so the only removals are the two that need a person watching.
        let unrestricted = Agent(name: "A", canSpawnSubAgents: true)
        let unrestrictedNames = Set(
            SubAgentExecutor.toolSet(for: unrestricted, depth: 1, settings: settings, all: everyTool).map(\.name)
        )
        XCTAssertEqual(unrestrictedNames, ["file_read", "file_write", "grep", "agent_spawn"])

        // An agent that cannot spawn loses agent_spawn as well, whatever the depth budget says.
        let cannotSpawn = Agent(name: "C", canSpawnSubAgents: false)
        let cannotSpawnNames = Set(
            SubAgentExecutor.toolSet(for: cannotSpawn, depth: 1, settings: settings, all: everyTool).map(\.name)
        )
        XCTAssertEqual(cannotSpawnNames, ["file_read", "file_write", "grep"])

        var restricted = Agent(name: "B")
        restricted.allowedToolIds = ["file_read"]
        let names = Set(SubAgentExecutor.toolSet(for: restricted, depth: 1, settings: settings, all: everyTool).map(\.name))
        XCTAssertEqual(names, ["file_read"])
    }

    func testDisabledToolsAreNotHandedToSubAgents() {
        let settings = AppSettings.default
        var tools = everyTool
        tools[0].isEnabled = false
        let names = Set(SubAgentExecutor.toolSet(for: Agent(name: "A"), depth: 1, settings: settings, all: tools).map(\.name))
        XCTAssertFalse(names.contains("file_read"))
    }

    /// A sub-agent that edited files and reports only "done" is worse than useless — the parent
    /// cannot review what it cannot see.
    func testTheReportNamesWhatChangedWhereAndWhatWasRefused() {
        let outcome = SubAgentExecutor.Outcome(
            succeeded: true,
            summary: "Renamed the symbol.",
            toolCallsMade: ["grep", "edit_file"],
            filesChanged: ["Sources/A.swift", "Sources/B.swift"],
            refusedActions: ["terminal_command — needs approval"],
            worktreePath: "/tmp/wt/sub-coder",
            branch: "swiftopenwork/sub-coder",
            iterations: 3,
            stoppedBecause: "completed",
            durationMs: 1200
        )
        let report = outcome.report
        XCTAssertTrue(report.contains("swiftopenwork/sub-coder"), "the parent must be told where the work is")
        XCTAssertTrue(report.contains("Sources/A.swift"))
        XCTAssertTrue(report.contains("Files changed (2)"))
        XCTAssertTrue(report.contains("terminal_command"), "a refusal must be surfaced, not swallowed")
        XCTAssertTrue(report.contains("Renamed the symbol."))
        XCTAssertTrue(report.contains("worktree_merge` with name `sub-coder`"), "the lead must know how to bring it back")
    }

    /// Failure must read as failure, so the parent cannot claim the work was done.
    func testAnIncompleteRunSaysSoRatherThanReadingAsSuccess() {
        let outcome = SubAgentExecutor.Outcome(
            succeeded: false, summary: "", toolCallsMade: [], filesChanged: [],
            refusedActions: [], worktreePath: nil, branch: nil,
            iterations: 6, stoppedBecause: "hit its 6-step budget", durationMs: 9
        )
        XCTAssertTrue(outcome.report.contains("did not complete"))
        XCTAssertTrue(outcome.report.contains("hit its 6-step budget"))
        XCTAssertTrue(outcome.report.contains("No files were changed."))
    }
}

/// `allowedToolIds` was shown in the Agents editor, editable there, stored on every agent — and
/// no execution path read it until sub-agents became real. The seeded value predates most of the
/// catalog, so the first code to honour it would have handed every sub-agent five useful tools
/// and called that the user's choice.
final class LegacyAgentAllowlistTests: XCTestCase {

    func testTheSeededAllowlistIsRecognisedAsNeverChosen() {
        XCTAssertTrue(PersistenceManager.isLegacySeededAllowlist([
            "file_read", "file_write", "terminal_command", "web_search",
            "calculator", "agent_spawn", "agent_message"
        ]))
        XCTAssertTrue(PersistenceManager.isLegacySeededAllowlist([
            "file_read", "file_write", "terminal_command", "web_search",
            "calculator", "agent_spawn", "agent_message", "memory_store", "memory_recall"
        ]), "the lead/research seeds carry the memory tools too")
    }

    /// A user who narrowed or widened the list expressed a preference, and keeps it.
    func testADeliberateAllowlistIsLeftAlone() {
        XCTAssertFalse(PersistenceManager.isLegacySeededAllowlist(["file_read"]))
        XCTAssertFalse(PersistenceManager.isLegacySeededAllowlist([
            "file_read", "file_write", "terminal_command", "web_search",
            "calculator", "agent_spawn", "agent_message", "grep"
        ]), "one added tool means someone chose this")
        XCTAssertFalse(PersistenceManager.isLegacySeededAllowlist([]))
    }

    /// New agents must not be born with a list that silently excludes most of the catalog.
    func testANewAgentCanUseEverythingByDefault() {
        XCTAssertTrue(Agent(name: "New").allowedToolIds.isEmpty)
    }
}
