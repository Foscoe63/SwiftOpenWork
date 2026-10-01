import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkEngine

@MainActor
final class AgentTerminalHostTests: XCTestCase {
    private nonisolated static func run(
        _ host: AgentTerminalHost, _ script: String, timeout: TimeInterval = 20
    ) async -> InteractiveCommandResult {
        await host.run(
            executable: "/bin/sh", arguments: ["-c", script], cwd: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            displayCommand: script, timeoutSeconds: timeout
        )
    }

    /// The point of the feature: the command stops for input, the user types it, the agent gets the result.
    func testCommandThatPromptsReceivesTypedAnswerAndReturnsItsOutput() async throws {
        let host = AgentTerminalHost.shared
        async let result = Self.run(host, "printf 'name? '; read n; echo HELLO-$n")

        // Wait for the prompt to appear in the terminal the user would be looking at.
        var sawPrompt = false
        for _ in 0..<100 {
            if host.isRunning, host.terminalView?.transcript().contains("name?") == true { sawPrompt = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawPrompt, "the prompt never reached the visible terminal")
        host.terminalView?.send(txt: "world\n")

        let finished = await result
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertTrue(finished.output.contains("HELLO-world"), finished.output)
        XCTAssertFalse(finished.timedOut)
        XCTAssertFalse(host.isRunning)
    }

    func testRawWaitStatusIsNormalised() {
        XCTAssertEqual(PTYExitStatus.normalize(0), 0)
        XCTAssertEqual(PTYExitStatus.normalize(768), 3)
        XCTAssertEqual(PTYExitStatus.normalize(9), 137, "killed by SIGKILL")
        XCTAssertNil(PTYExitStatus.normalize(nil))
    }

    func testNonZeroExitIsReported() async {
        let result = await Self.run(AgentTerminalHost.shared, "echo oops; exit 3")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.output.contains("oops"))
    }

    func testACommandNobodyAnswersIsTerminatedAtTheTimeout() async {
        let started = Date()
        let result = await Self.run(AgentTerminalHost.shared, "printf 'waiting: '; sleep 60", timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.output.contains("waiting:"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testRunsAreSerialisedSoTwoPromptsNeverShareTheKeyboard() async {
        let host = AgentTerminalHost.shared
        async let first = Self.run(host, "echo A; sleep 1; echo A2")
        async let second = Self.run(host, "echo B")
        let (a, b) = await (first, second)
        XCTAssertTrue(a.output.contains("A2"))
        XCTAssertFalse(a.output.contains("B"), "second command's output leaked into the first")
        XCTAssertTrue(b.output.contains("B"))
    }
}
