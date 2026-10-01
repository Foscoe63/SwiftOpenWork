import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

@MainActor
final class AgentTerminalHostTests: XCTestCase {
    private nonisolated static func start(
        _ host: AgentTerminalHost, _ script: String, timeout: TimeInterval = 20, idle: TimeInterval = 1
    ) async -> InteractiveCommandResult {
        await host.run(
            executable: "/bin/sh", arguments: ["-c", script], cwd: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            displayCommand: script, timeoutSeconds: timeout, idleSeconds: idle
        )
    }

    private func cleanUp() async {
        _ = await AgentTerminalHost.shared.sendInput("", idleSeconds: 1, terminate: true)
    }

    /// The point of the feature: the command stops for input, the agent answers, and each call
    /// reports only what is new.
    func testAgentAnswersAPromptWithSendInput() async {
        let host = AgentTerminalHost.shared
        let first = await Self.start(host, "printf 'name? '; read n; echo HELLO-$n")
        XCTAssertTrue(first.stillRunning, "a command waiting on input must return as still running")
        XCTAssertNil(first.exitCode)
        XCTAssertTrue(first.output.contains("name?"), first.output)
        XCTAssertTrue(host.isRunning)

        let second = await host.sendInput("world\r", idleSeconds: 1, terminate: false)
        XCTAssertFalse(second.stillRunning)
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertTrue(second.output.contains("HELLO-world"), second.output)
        XCTAssertFalse(second.output.contains("name?"), "the earlier prompt must not be reported twice: \(second.output)")
    }

    func testMultiStepWizardKeepsTheSameSession() async {
        let host = AgentTerminalHost.shared
        let a = await Self.start(host, "printf 'one? '; read a; printf 'two? '; read b; echo DONE-$a-$b")
        XCTAssertTrue(a.stillRunning)
        let b = await host.sendInput("x\r", idleSeconds: 1, terminate: false)
        XCTAssertTrue(b.stillRunning)
        XCTAssertTrue(b.output.contains("two?"))
        let c = await host.sendInput("y\r", idleSeconds: 1, terminate: false)
        XCTAssertEqual(c.exitCode, 0)
        XCTAssertTrue(c.output.contains("DONE-x-y"), c.output)
    }

    func testAnotherCommandIsRefusedWhileOneIsWaiting() async {
        let host = AgentTerminalHost.shared
        _ = await Self.start(host, "printf 'ready? '; read x")
        let refused = await Self.start(host, "echo nope")
        XCTAssertNotNil(refused.refusal)
        XCTAssertTrue(refused.refusal?.contains("send_input") ?? false)
        await cleanUp()
    }

    func testTerminateEndsTheSession() async {
        let host = AgentTerminalHost.shared
        _ = await Self.start(host, "printf 'stuck: '; sleep 60")
        let ended = await host.sendInput("", idleSeconds: 2, terminate: true)
        XCTAssertFalse(ended.stillRunning)
        XCTAssertNotNil(ended.exitCode)
        XCTAssertNotEqual(ended.exitCode, 0)
        XCTAssertFalse(host.isRunning)
    }

    func testSendInputWithNothingRunningIsRefused() async {
        await cleanUp()
        let result = await AgentTerminalHost.shared.sendInput("hi\r", idleSeconds: 1, terminate: false)
        XCTAssertNotNil(result.refusal)
    }

    func testNonZeroExitIsReportedWithTheNormalisedCode() async {
        let result = await Self.start(AgentTerminalHost.shared, "echo oops; exit 3")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.stillRunning)
        XCTAssertTrue(result.output.contains("oops"))
    }

    func testACommandNobodyAnswersIsTerminatedAtTheTimeLimit() async {
        let started = Date()
        let result = await Self.start(AgentTerminalHost.shared, "printf 'waiting: '; sleep 60", timeout: 1, idle: 30)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.stillRunning)
        XCTAssertTrue(result.output.contains("waiting:"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testRawWaitStatusIsNormalised() {
        XCTAssertEqual(PTYExitStatus.normalize(0), 0)
        XCTAssertEqual(PTYExitStatus.normalize(768), 3)
        XCTAssertEqual(PTYExitStatus.normalize(9), 137, "killed by SIGKILL")
        XCTAssertNil(PTYExitStatus.normalize(nil))
    }
}
