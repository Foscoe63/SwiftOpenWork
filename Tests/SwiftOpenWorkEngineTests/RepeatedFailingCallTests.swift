import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// A model called `screenshot_window` with identical arguments eight times and was still going
/// when the user stopped it by hand. Dead-end detection existed only for MCP (`mcpDeadEnds`), so
/// a first-party tool could fail the same way forever. The model was not being stupid: nothing
/// told it the attempt was hopeless, and retrying once is a reasonable thing to do.
@MainActor
final class RepeatedFailingCallTests: XCTestCase {

    func testTheSameCallWithTheSameArgumentsHasTheSameSignature() {
        let a = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}"#)
        let b = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}  "#)
        XCTAssertEqual(a, b, "trailing whitespace must not disguise a repeat")
    }

    /// Changing the arguments is a new attempt, not a repeat — it must not be blocked.
    func testDifferentArgumentsAreADifferentCall() {
        let a = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}"#)
        let b = AgentRunner.callSignature("screenshot_window", #"{"app":"Finder"}"#)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentToolsAreDifferentCalls() {
        XCTAssertNotEqual(
            AgentRunner.callSignature("screenshot_window", "{}"),
            AgentRunner.callSignature("accessibility_tree", "{}")
        )
    }

    /// One retry is reasonable; the third identical attempt is a loop rather than a strategy.
    func testTheLimitAllowsARetryButNotALoop() {
        XCTAssertEqual(AgentRunner.identicalFailureLimit, 2)

        var failures: [String: Int] = [:]
        let key = AgentRunner.callSignature("screenshot_window", #"{"app":"OpenWork"}"#)

        var executions = 0
        for _ in 0..<8 {
            if let prior = failures[key], prior >= AgentRunner.identicalFailureLimit { continue }
            executions += 1
            failures[key, default: 0] += 1   // every attempt fails
        }
        XCTAssertEqual(executions, 2, "eight attempts must cost two executions, not eight")
    }

    /// A success clears the count, so a tool that starts working is not punished for its past.
    func testASuccessResetsTheCount() {
        var failures: [String: Int] = [:]
        let key = AgentRunner.callSignature("run_app", "{}")
        failures[key] = 2
        failures[key] = 0   // the success path
        XCTAssertLessThan(failures[key] ?? 0, AgentRunner.identicalFailureLimit)
    }
}

/// The loop breaker has to watch reasoning, not only visible text.
///
/// It was gated on `deltaText` being non-empty, which held while reasoning arrived inline in the
/// visible stream. Once `ReasoningChannel` began routing an unclosed `<think>` block to
/// `deltaReasoning`, `deltaText` stayed empty for the whole turn and the breaker never ran — an
/// exported session shows 12,117 characters of reasoning over 192.7 seconds with zero visible
/// output, stopped by hand. Reasoning models spiral exactly where the visible text never grows,
/// which is the case this was built for.
final class LoopBreakerWatchesReasoningTests: XCTestCase {

    func testARepeatingReasoningStreamIsDetected() {
        let spiral = String(repeating: "Let me reconsider the screenshot I cannot see. ", count: 40)
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: spiral),
                      "a degenerate reasoning stream must be detectable")
    }

    func testOrdinaryReasoningIsNotFlaggedAsALoop() {
        let normal = """
        The user wants the accessibility tree for Finder. I should call the tool rather than
        guess. If it fails I will report the error verbatim and say what would unblock it,
        because inventing a tree would be worse than returning nothing at all.
        """
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: normal))
    }

    /// A turn that spirals in reasoning produces no visible text, so `deltaText` alone can never
    /// be the trigger.
    func testAReasoningOnlyStreamHasNoVisibleTextToTriggerOn() {
        let chunk = LLMStreamChunk(deltaText: "", deltaReasoning: "thinking and thinking")
        XCTAssertTrue(chunk.deltaText.isEmpty,
                      "gating the breaker on deltaText skips this chunk entirely")
        XCTAssertNotNil(chunk.deltaReasoning)
    }
}

/// A missing path retried with a different offset or limit is one dead end, not new attempts.
final class MissingPathRepeatTests: XCTestCase {
    func testOffsetAndLimitDoNotChangeTheMissingPathKey() {
        let a = AgentRunner.missingPathKey("file_read", #"{"path":"/w/CleanUpEngine.swift","offset":"170.0","limit":"50.0"}"#, workspaceRoot: "/w")
        let b = AgentRunner.missingPathKey("read_file", #"{"limit":50,"path":"/w/CleanUpEngine.swift","offset":137}"#, workspaceRoot: "/w")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertNil(AgentRunner.missingPathKey("build_project", "{}", workspaceRoot: "/w"))
    }

    func testHintKeepsTheSuggestion() {
        let text = "Error: no such file.\nDid you mean: `MacClean/Services/CleanupEngine.swift`?"
        XCTAssertEqual(AgentRunner.didYouMeanHint(in: text), "Did you mean: `MacClean/Services/CleanupEngine.swift`?")
        XCTAssertTrue(AgentRunner.didYouMeanHint(in: "does not exist").contains("glob"))
        XCTAssertTrue(AgentRunner.isMissingPathFailure("The file does not exist."))
        XCTAssertFalse(AgentRunner.isMissingPathFailure("permission denied"))
    }
}
