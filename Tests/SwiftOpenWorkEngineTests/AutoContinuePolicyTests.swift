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

    /// The two lines that ended turns in a real Qwen3-Coder-Next session.
    func testCodingVerbsAreStalls() {
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "I can see there are still duplicate scanning loops. Let me remove the duplicate loop (lines 108-139) to fix this properly."))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent("Now let me build the project to verify the fix."))
        XCTAssertTrue(AutoContinuePolicy.endsWithUnfulfilledIntent("The import is missing. Let me fix that"))
    }

    func testFinishedAnswersAreNotStalls() {
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "I renamed the function and updated callers. Now let me know if you'd like changes."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent(
            "First, let me explain the fix.\nThe bug was an off-by-one in the parser."))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent("Should I check the logs too? Let me check?"))
        XCTAssertFalse(AutoContinuePolicy.endsWithUnfulfilledIntent(""))
    }

    func testNudgeNoLongerNamesAFallbackTool() throws {
        let source = try String(contentsOf: SourceTree.url("Engine/Agents/AgentRunner.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(#"?? "mcp_call""#), "the nudge pointed models at a tool that may not exist")
    }

    /// The nudge used to stop after step five, so a long coding turn ended on its own narration.
    func testNudgeIsCappedByStreakNotByStepNumber() throws {
        let source = try String(contentsOf: SourceTree.url("Engine/Agents/AgentRunner.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("&& iteration < 6"))
        XCTAssertTrue(source.contains("intentNudgeStreak < Self.maxConsecutiveIntentNudges"))
    }
}

