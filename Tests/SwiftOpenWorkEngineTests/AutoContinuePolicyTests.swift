import XCTest
@testable import SwiftOpenWorkCore

/// `AutoContinuePolicy` is what tells a turn that trailed off mid-task ("Now let me check
/// TerminalManager...", no tool call, todo list still open) apart from one that is actually
/// finished ("Hi! How can I help?", no tool call, no todos) — both look identical from the ReAct
/// loop's own point of view: a step with no tool calls.
final class AutoContinuePolicyTests: XCTestCase {

    func testAnExplicitStopIsNeverResumedAutomatically() {
        XCTAssertFalse(AutoContinuePolicy.shouldAutoContinue(
            haltReason: "stopped", finalText: "Here is where I got to.", pendingTodos: true
        ))
    }

    func testARoundCapHaltAlwaysContinuesRegardlessOfTodos() {
        XCTAssertTrue(AutoContinuePolicy.shouldAutoContinue(
            haltReason: "round_cap", finalText: "Reached the autonomous round cap.", pendingTodos: false
        ))
    }

    func testAnOrdinaryFinishedReplyWithNoPendingWorkIsNotResumed() {
        // "hello" -> "Hi! How can I help?" must not loop forever just because it made no tool call.
        XCTAssertFalse(AutoContinuePolicy.shouldAutoContinue(
            haltReason: nil, finalText: "Hi! How can I help?", pendingTodos: false
        ))
    }

    func testATrailedOffReplyWithPendingTodosIsResumed() {
        XCTAssertTrue(AutoContinuePolicy.shouldAutoContinue(
            haltReason: nil,
            finalText: "Now let me check TerminalManager to see if scroll position restoration is already implemented:",
            pendingTodos: true
        ))
    }

    func testARealQuestionWithPendingTodosIsNotResumed() {
        XCTAssertFalse(AutoContinuePolicy.shouldAutoContinue(
            haltReason: nil,
            finalText: "I found two ways to fix the SSH password leak. Which do you want: an askpass script, or the system keychain?",
            pendingTodos: true
        ))
    }

    func testAQuestionEarlierInTheTextDoesNotCountOnlyTheLastLineDoes() {
        // A question about the code, buried in a status update, is not a question for the reader.
        XCTAssertTrue(AutoContinuePolicy.shouldAutoContinue(
            haltReason: nil,
            finalText: "Should this use askpass or keychain? I'll go with keychain for now.\nNext: wiring SSHSessionManager.",
            pendingTodos: true
        ))
    }

    func testAnUnrecognisedHaltReasonIsNotResumedBlindly() {
        XCTAssertFalse(AutoContinuePolicy.shouldAutoContinue(
            haltReason: "some_future_reason", finalText: "...", pendingTodos: true
        ))
    }

    func testEmptyTextWithPendingTodosIsResumed() {
        XCTAssertTrue(AutoContinuePolicy.shouldAutoContinue(haltReason: nil, finalText: "", pendingTodos: true))
    }
}

/// The in-turn "stop narrating" nudge: only a step that *ends* on an announced action is a stall.
final class UnfulfilledIntentTests: XCTestCase {
    func testTrailingAnnouncedActionIsAStall() {
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "Now let me check TerminalManager to see if scroll position restoration is already implemented:"))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent("I found the bug. Let me read Config.swift..."))
    }

    func testFinishedAnswersAreNotStalls() {
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "I renamed the function and updated callers. Now let me know if you'd like changes."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "First, let me explain the fix.\nThe bug was an off-by-one in the parser."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent("Should I check the logs too? Let me check?"))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent(""))
    }

    /// Step endings from a real session that ended the turn instead of being nudged.
    func testEditAndBuildAnnouncementsAreStalls() {
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent("Now let me build the project to verify the fix."))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "The second loop is redundant. Let me remove the duplicate loop (lines 108-139) to fix this properly."))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent("Let me fix the error in `FilePreviewView.swift`:"))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "I see the issue. I need to fix this by removing lines 107-162."))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent("Now I'll update PrivilegedCleanup to use PathGuard."))
    }

    func testSignOffsAreNotStalls() {
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent("The build passes. Let me know if you want tests too."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent("Done. Let me explain what changed."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent("I'll leave the migration to you."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent("All four errors are fixed and the project builds."))
    }

    func testNudgeIsNotLimitedToTheFirstRounds() throws {
        let source = try String(contentsOf: SourceTree.url("Engine/Agents/AgentRunner.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("&& iteration < 6"), "stalls after round six ended the turn un-nudged")
    }

    func testNudgeNoLongerNamesAFallbackTool() throws {
        let source = try String(contentsOf: SourceTree.url("Engine/Agents/AgentRunner.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(#"?? "mcp_call""#), "the nudge pointed models at a tool that may not exist")
    }
}

