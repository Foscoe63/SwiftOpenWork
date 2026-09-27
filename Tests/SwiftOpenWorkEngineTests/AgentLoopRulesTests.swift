import XCTest
@testable import SwiftOpenWorkCore

/// The verdict reader is the only thing between "the model said some words" and "this step is
/// finished". It is pure, so every shape it has to survive is reachable with a string.
final class AgentLoopRulesTests: XCTestCase {

    func testPassAndFailAreRead() {
        XCTAssertTrue(LoopRules.readVerdict("Looks good.\nVERDICT: PASS").pass)
        let f = LoopRules.readVerdict("VERDICT: FAIL — the tests are missing")
        XCTAssertFalse(f.pass)
        XCTAssertEqual(f.reason, "the tests are missing")
    }

    func testTheLastVerdictWins() {
        // A model that quotes its instructions back must not pass on the first line it echoed.
        XCTAssertFalse(LoopRules.readVerdict("VERDICT: PASS\nVERDICT: FAIL — nope").pass)
        XCTAssertTrue(LoopRules.readVerdict("VERDICT: FAIL — x\nVERDICT: PASS").pass)
    }

    func testAVerdictMustStartALine() {
        XCTAssertFalse(LoopRules.readVerdict("I would not say VERDICT: PASS here").pass)
    }

    func testNoVerdictAndEmptyAreFailsNeverPasses() {
        XCTAssertFalse(LoopRules.readVerdict("It seems fine to me.").pass)
        let empty = LoopRules.readVerdict("  \n ")
        XCTAssertFalse(empty.pass)
        XCTAssertTrue(empty.reason.contains("nothing at all"))
    }

    func testListMarkersAndBoldAreTolerated() {
        XCTAssertTrue(LoopRules.readVerdict("- **VERDICT: PASS**").pass)
        XCTAssertTrue(LoopRules.readVerdict("> VERDICT: PASS").pass)
        XCTAssertFalse(LoopRules.readVerdict("VERDICT: PASSED").pass)
    }

    func testCommandVerdicts() {
        XCTAssertTrue(LoopRules.readCommandVerdict(.init(exitCode: 0, output: "ok")).pass)
        let bad = LoopRules.readCommandVerdict(.init(exitCode: 2, output: "boom"))
        XCTAssertFalse(bad.pass)
        XCTAssertTrue(bad.reason.contains("exited 2") && bad.reason.contains("boom"))
        let spawn = LoopRules.readCommandVerdict(.init(exitCode: nil, output: "", spawnError: "no shell"))
        XCTAssertTrue(spawn.couldNotRun)
        let slow = LoopRules.readCommandVerdict(.init(exitCode: nil, output: "", timedOut: true, timeoutSeconds: 120))
        XCTAssertTrue(slow.reason.contains("120s"))
    }

    func testEvidenceKeepsTheTailNotTheHead() {
        let out = "BANNER" + String(repeating: "x", count: 2000) + "FAILURE SUMMARY"
        let v = LoopRules.readCommandVerdict(.init(exitCode: 1, output: out))
        XCTAssertTrue(v.reason.contains("FAILURE SUMMARY"))
        XCTAssertFalse(v.reason.contains("BANNER"))
    }

    func testRetryPromptCarriesTheReasonAndAScope() {
        var step = LoopStep(title: "Write it", check: "file exists")
        var loop = AgentLoop(title: "Ship", steps: [step])
        XCTAssertFalse(LoopRules.workPrompt(loop: loop, step: step).contains("WHY:"))
        step.lastFail = "no file"
        loop.steps = [step]
        let p = LoopRules.workPrompt(loop: loop, step: step)
        XCTAssertTrue(p.contains("WHY: no file"))
        XCTAssertTrue(p.contains("SCOPE:"))
    }

    func testNormalizationClampsAndDropsBlankSteps() {
        var l = AgentLoop(title: "  T  ", steps: [
            LoopStep(title: "  ", maxAttempts: 5),
            LoopStep(title: "a", maxAttempts: 99)
        ], maxPasses: 0, everyMinutes: 0)
        l = LoopRules.normalized(l)
        XCTAssertEqual(l.title, "T")
        XCTAssertEqual(l.steps.count, 1)
        XCTAssertEqual(l.steps[0].maxAttempts, LoopRules.maxAttempts)
        XCTAssertEqual(l.maxPasses, 1)
        XCTAssertEqual(l.everyMinutes, LoopRules.minEveryMinutes)
    }

    func testScheduleIsMeasuredFromTheLastRunAndGivesUpAfterTwoFailures() {
        let now = Date()
        var l = AgentLoop(title: "t", everyMinutes: 60, lastRunAt: now.addingTimeInterval(-3 * 3600))
        XCTAssertTrue(LoopRules.isDue(l, now: now))
        l.lastRunAt = now.addingTimeInterval(-60)
        XCTAssertFalse(LoopRules.isDue(l, now: now))
        l.lastRunAt = now.addingTimeInterval(-3 * 3600)
        l.state = .running
        XCTAssertFalse(LoopRules.isDue(l, now: now))

        var s = AgentLoop(title: "t", everyMinutes: 5)
        s = LoopRules.afterRun(s, failed: true)
        XCTAssertNotNil(s.everyMinutes)
        s = LoopRules.afterRun(s, failed: true)
        XCTAssertNil(s.everyMinutes)
        XCTAssertNotNil(s.scheduleOffReason)
    }
}
