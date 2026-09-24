import XCTest
@testable import SwiftOpenWorkEngine

final class ProcessTreeTests: XCTestCase {

    func testDescendantsAreListedChildrenFirst() {
        let ps = "  10 1\n 11 10\n 12 11\n 13 1\n 99 50\n"
        XCTAssertEqual(ProcessTree.descendants(of: 10, inPsOutput: ps), [12, 11])
        XCTAssertEqual(ProcessTree.descendants(of: 1, inPsOutput: ps), [12, 11, 10, 13])
        XCTAssertEqual(ProcessTree.descendants(of: 77, inPsOutput: ps), [])
    }

    func testMalformedPsLinesAreIgnored() {
        XCTAssertEqual(ProcessTree.descendants(of: 1, inPsOutput: "garbage\n 2 1\n x y\n"), [2])
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
        XCTAssertFalse(ProcessTree.descendants(of: shell.processIdentifier).isEmpty, "the sleep should be running under the shell")

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
