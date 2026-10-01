import XCTest
@testable import SwiftOpenWork

@MainActor
final class InteractiveTerminalTests: XCTestCase {
    private func screenText(_ host: InteractiveTerminalHost) -> String {
        String(decoding: host.terminalView.terminal.getBufferAsData(), as: UTF8.self)
    }

    private func waitFor(_ host: InteractiveTerminalHost, contains needle: String, seconds: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if screenText(host).contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// The whole point of a PTY: a program that prompts and waits for a typed answer.
    func testShellRunsCommandsAndAnswersAnInteractivePrompt() async throws {
        let host = InteractiveTerminalHost.shared
        host.restart(directory: NSTemporaryDirectory())
        XCTAssertTrue(host.isRunning)

        // Arithmetic in the command so the echoed *input* cannot satisfy the assertion by itself.
        host.send("echo PTYOK$((1+2))\n")
        let ran = await waitFor(host, contains: "PTYOK3")
        XCTAssertTrue(ran, "command output never reached the emulator")

        // `read` blocks on the terminal until a line is typed: impossible over a plain pipe runner.
        host.send("printf 'name? '; read n; echo HELLO-$n\n")
        _ = await waitFor(host, contains: "name?")
        host.send("world\n")
        let answered = await waitFor(host, contains: "HELLO-world")
        XCTAssertTrue(answered, "the typed answer did not reach the program")

        host.terminate()
        XCTAssertFalse(host.isRunning)
    }
}
