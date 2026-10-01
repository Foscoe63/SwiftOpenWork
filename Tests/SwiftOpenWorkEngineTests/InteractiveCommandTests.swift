import XCTest
@testable import SwiftOpenWorkEngine

final class InteractiveCommandTests: XCTestCase {
    func testBoolArgumentAcceptsWhatModelsActuallySend() {
        XCTAssertEqual(ToolExecutionEngine.boolArgument(true), true)
        XCTAssertEqual(ToolExecutionEngine.boolArgument("true"), true)
        XCTAssertEqual(ToolExecutionEngine.boolArgument("False"), false)
        XCTAssertEqual(ToolExecutionEngine.boolArgument(1), true)
        XCTAssertEqual(ToolExecutionEngine.boolArgument(0), false)
        XCTAssertNil(ToolExecutionEngine.boolArgument("maybe"))
        XCTAssertNil(ToolExecutionEngine.boolArgument(nil))
    }

    func testFormattingDistinguishesSuccessFailureTimeoutAndStop() {
        let ok = InteractiveCommandFormatting.format(InteractiveCommandResult(output: " done \n", exitCode: 0), timeoutSeconds: 600)
        XCTAssertTrue(ok.success); XCTAssertEqual(ok.output, "done"); XCTAssertNil(ok.error)

        let failed = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "x", exitCode: 2), timeoutSeconds: 600)
        XCTAssertFalse(failed.success); XCTAssertEqual(failed.error, "Process exited with code 2")

        let timedOut = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "p", exitCode: nil, timedOut: true), timeoutSeconds: 600)
        XCTAssertFalse(timedOut.success); XCTAssertTrue(timedOut.error?.contains("600s") ?? false)

        let stopped = InteractiveCommandFormatting.format(InteractiveCommandResult(output: "p", exitCode: nil, cancelled: true), timeoutSeconds: 600)
        XCTAssertTrue(stopped.error?.contains("stopped") ?? false)
    }

    func testOversizedOutputKeepsTheEnd() {
        let big = String(repeating: "a", count: 300_000) + "TAIL"
        let out = InteractiveCommandFormatting.format(InteractiveCommandResult(output: big, exitCode: 0), timeoutSeconds: 1).output
        XCTAssertEqual(out.count, InteractiveCommandFormatting.maxCharacters)
        XCTAssertTrue(out.hasSuffix("TAIL"))
    }

    func testRegistryHoldsTheRegisteredRunner() {
        struct Stub: InteractiveCommandRunner {
            func run(executable: String, arguments: [String], cwd: String, environment: [String: String], displayCommand: String, timeoutSeconds: TimeInterval) async -> InteractiveCommandResult {
                InteractiveCommandResult(output: "stub", exitCode: 0)
            }
        }
        let before = InteractiveCommandRegistry.runner
        InteractiveCommandRegistry.register(Stub())
        XCTAssertNotNil(InteractiveCommandRegistry.runner)
        InteractiveCommandRegistry.register(before)
    }
}
