import XCTest
@testable import SwiftOpenWorkEngine

final class ProcessTreeTests: XCTestCase {

    func testTerminationFindsTheSameDescendantsThePreviewCodeDoes() {
        let pairs = ProcessTree.parse(psOutput: "  10 1\n 11 10\n 12 11\n 13 1\n 99 50\n")
        XCTAssertEqual(Set(ProcessTree.descendants(of: 10, in: pairs)), [11, 12])
        XCTAssertTrue(ProcessTree.descendants(of: 77, in: pairs).isEmpty)
    }

    /// The bug: terminating only the shell left the process it started running, holding the pipe.
    func testTerminatingTheShellAlsoStopsItsChildren() throws {
        let marker = "sleep 47\(Int.random(in: 100...999))"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", "\(marker) & wait"]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(ProcessTree.liveDescendants(of: shell.processIdentifier).isEmpty, "the sleep should be running under the shell")

        ProcessTree.terminate(shell.processIdentifier, grace: 0.5)
        shell.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.0)

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        pgrep.standardOutput = FileHandle.nullDevice
        try pgrep.run()
        pgrep.waitUntilExit()
        XCTAssertNotEqual(pgrep.terminationStatus, 0, "the child must not outlive its shell")
    }
}
