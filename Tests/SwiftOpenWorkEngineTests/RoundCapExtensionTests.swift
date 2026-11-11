import XCTest
@testable import SwiftOpenWorkEngine

/// A turn that reaches its round cap while its tool calls are succeeding used to stop and wait
/// for Continue. It now takes up to `maxRoundExtensions` more allowances first. The rule lives in
/// `AgentTurn`, which needs a model to run, so these pin its conditions and wiring.
final class RoundCapExtensionTests: XCTestCase {
    private func turnSource() throws -> String { try SourceTree.read("AgentTurn.swift") }

    func testTheLoopAsksBeforeStoppingAtTheCap() throws {
        let source = try turnSource()
        XCTAssertTrue(source.contains("while iteration < roundLimit || extendRoundLimitIfProgressing()"))
        XCTAssertTrue(source.contains("iteration >= roundLimit {"), "the round_cap halt must use the extended limit")
    }

    func testExtensionNeedsProgressAndNoHaltAndIsBounded() throws {
        let source = try turnSource()
        for condition in ["!halted", "!finishedNaturally", "roundExtensions < Self.maxRoundExtensions",
                          "succeededCallsThisStep > 0", "mcpDeadEnds < 3"] {
            XCTAssertTrue(source.contains(condition), condition)
        }
        XCTAssertEqual(AgentTurn.maxRoundExtensions, 0, "extensions are off: they tripled the rounds a turn could spend")
    }

    func testSuccessfulCallsAreCountedPerStep() throws {
        let source = try turnSource()
        XCTAssertTrue(source.contains("succeededCallsThisStep = 0"))
        XCTAssertTrue(source.contains("if outcome.success { succeededCallsThisStep += 1 }"))
    }
}
