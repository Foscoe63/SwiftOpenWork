import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Compaction that fires on token count alone can land mid-task, throwing away files just read and
/// not yet used. A milestone — a green test run, a clean tree — is the opposite: the work behind it
/// is finished, so it is the cheapest moment to trade detail for room.
final class MilestoneCompactionTests: XCTestCase {

    func testGreenTestRunIsAMilestone() {
        XCTAssertTrue(ContextCompactor.isMilestone(
            toolName: "run_tests",
            succeeded: true,
            output: "Test Suite 'All tests' passed. Build succeeded."
        ))
    }

    func testFailedRunIsNotAMilestone() {
        XCTAssertFalse(ContextCompactor.isMilestone(
            toolName: "run_tests",
            succeeded: false,
            output: "Build succeeded, 3 tests failed"
        ))
    }

    /// A run can exit zero and still report compile errors in its output; that is not settled work.
    func testSucceededRunReportingErrorsIsNotAMilestone() {
        XCTAssertFalse(ContextCompactor.isMilestone(
            toolName: "build_project",
            succeeded: true,
            output: "Build succeeded with 1 error: Foo.swift:2: error: bad"
        ))
    }

    func testCleanTreeIsAMilestone() {
        XCTAssertTrue(ContextCompactor.isMilestone(
            toolName: "git_status",
            succeeded: true,
            output: "On branch main\nnothing to commit, working tree clean"
        ))
    }

    func testDirtyTreeIsNotAMilestone() {
        XCTAssertFalse(ContextCompactor.isMilestone(
            toolName: "git_status",
            succeeded: true,
            output: "On branch main\nChanges not staged for commit:\n\tmodified: A.swift"
        ))
    }

    /// Reading a file successfully is progress, not a milestone — the next step still needs it.
    func testOrdinaryToolIsNotAMilestone() {
        XCTAssertFalse(ContextCompactor.isMilestone(
            toolName: "read_file",
            succeeded: true,
            output: "1\tlet x = 1"
        ))
    }

    func testMilestoneCompactionLeavesShortSessionsAlone() {
        let messages = (0..<6).map { i in
            ChatMessage(sessionId: "s", role: i == 0 ? .user : .assistant, content: "m\(i)")
        }
        let result = ContextCompactor.compactAtMilestone(messages)
        XCTAssertFalse(result.didCompact)
        XCTAssertEqual(result.messages.count, 6)
    }

    /// The point of compacting early is that it happens without token pressure — so a long but
    /// cheap session must still compact.
    func testMilestoneCompactionFiresWithoutTokenPressure() {
        var messages: [ChatMessage] = [
            ChatMessage(sessionId: "s", role: .user, content: "Fix the failing test")
        ]
        for i in 0..<19 {
            messages.append(ChatMessage(sessionId: "s", role: .assistant, content: "step \(i)"))
        }
        messages[3].toolCalls = [Self.call("edit_file", #"{"path":"A.swift"}"#)]
        XCTAssertLessThan(ContextCompactor.estimateTokens(messages), 200, "fixture must be cheap")

        let result = ContextCompactor.compactAtMilestone(messages)
        XCTAssertTrue(result.didCompact)
        XCTAssertLessThan(result.messages.count, messages.count)
        XCTAssertEqual(result.messages.first?.content, "Fix the failing test",
                       "the task must survive; forgetting it is how an agent finishes the wrong job")
        XCTAssertEqual(result.messages.last?.content, "step 18")
    }

    private static func call(_ tool: String, _ args: String) -> ToolCallInfo {
        ToolCallInfo(toolName: tool, argumentsJson: args, status: .success)
    }

    /// Read files, build once green, nothing changed: not a milestone worth forgetting the reads for.
    /// A real session compacted here twice and then re-read the same files in a circle.
    func testMilestoneCompactionSkipsAnExplorationOnlyStretch() {
        var messages: [ChatMessage] = [ChatMessage(sessionId: "s", role: .user, content: "Review this")]
        for i in 0..<19 {
            messages.append(ChatMessage(sessionId: "s", role: .assistant, content: "step \(i)"))
        }
        messages[2].toolCalls = [Self.call("read_file", #"{"path":"A.swift"}"#)]
        messages[4].toolCalls = [Self.call("build_project", "{}")]

        let result = ContextCompactor.compactAtMilestone(messages)
        XCTAssertFalse(result.didCompact)
        XCTAssertEqual(result.messages.count, messages.count)
    }
}
