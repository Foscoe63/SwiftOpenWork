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
