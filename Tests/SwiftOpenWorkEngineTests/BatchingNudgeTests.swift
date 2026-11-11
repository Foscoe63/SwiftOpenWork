import XCTest
@testable import SwiftOpenWorkEngine

/// A turn that reads one file per step burns its round cap on exploring. The nudge is wired in
/// `AgentTurn`, which needs a model to run, so these pin the wiring and the wording.
final class BatchingNudgeTests: XCTestCase {
    func testTheTurnCountsSoloReadStepsAndNudgesOnce() throws {
        let source = try SourceTree.read("AgentTurn.swift")
        XCTAssertTrue(source.contains("batchingNudge(for: pendingCallsToExecute)"))
        XCTAssertTrue(source.contains("guard soloReadSteps >= 4, !batchingNudgeSent"))
        XCTAssertTrue(source.contains("[System]:"), "a [System] note is dropped from the saved transcript")
    }

    func testOnlyReadOnlyToolsCountAsExploration() {
        XCTAssertTrue(AgentRunner.isParallelSafe("grep"))
        XCTAssertTrue(AgentRunner.isParallelSafe("file_read"))
        XCTAssertFalse(AgentRunner.isParallelSafe("edit_file"))
    }
}
