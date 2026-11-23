import XCTest
@testable import SwiftOpenWorkEngine

final class CompletionCheckTests: XCTestCase {
    private func log(_ steps: [(String, String, Bool)]) -> CompletionCheck.Log {
        var l = CompletionCheck.Log()
        for (tool, path, ok) in steps { l.record(toolName: tool, argumentsJson: #"{"path":"\#(path)"}"#, success: ok) }
        return l
    }

    func testNothingChangedNothingToCheck() {
        XCTAssertNil(CompletionCheck.problem(log: log([("file_read", "a.swift", true)]), request: "explain it", finalText: "done"))
    }

    func testEditsWithoutACheckSendTheAgentBack() {
        let p = CompletionCheck.problem(log: log([("edit_file", "a.swift", true)]), request: "fix it", finalText: "done")
        XCTAssertTrue(p?.contains("not verified") ?? false)
    }

    func testACheckAfterTheLastEditLetsItFinish() {
        XCTAssertNil(CompletionCheck.problem(log: log([("edit_file", "a.swift", true), ("build_project", "", true)]), request: "fix it", finalText: "done"))
        // An edit after the check makes the check stale.
        XCTAssertNotNil(CompletionCheck.problem(log: log([("build_project", "", true), ("edit_file", "a.swift", true)]), request: "fix it", finalText: "done"))
    }

    func testAFailedCheckNeedsFixingOrAdmitting() {
        let l = log([("edit_file", "a.swift", true), ("build_project", "", false)])
        XCTAssertNotNil(CompletionCheck.problem(log: l, request: "fix it", finalText: "All done!"))
        XCTAssertNil(CompletionCheck.problem(log: l, request: "fix it", finalText: "The build still fails because of X."))
    }

    func testUnrequestedTestsAndDocsAreFlagged() {
        let l = log([("file_write", "Tests/FooTests.swift", true), ("build_project", "", true)])
        XCTAssertTrue(CompletionCheck.problem(log: l, request: "fix the bug", finalText: "done")?.contains("did not ask for") ?? false)
        XCTAssertNil(CompletionCheck.problem(log: l, request: "fix the bug and add a test", finalText: "done"))
        let d = log([("file_write", "NOTES.md", true), ("build_project", "", true)])
        XCTAssertNotNil(CompletionCheck.problem(log: d, request: "fix the bug", finalText: "done"))
        XCTAssertNil(CompletionCheck.problem(log: d, request: "write up notes", finalText: "done"))
    }
}
