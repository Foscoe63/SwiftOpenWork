import XCTest
@testable import SwiftOpenWorkEngine

final class CommandReviewerTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func workspace(rules: String) throws -> String {
        let d = try dir()
        try FileManager.default.createDirectory(at: d.appendingPathComponent(".swiftopenwork"), withIntermediateDirectories: true)
        try rules.write(to: d.appendingPathComponent(".swiftopenwork/adversary.md"), atomically: true, encoding: .utf8)
        return d.path
    }
    struct Boom: Error {}

    func testParseBlocksOnlyOnBlock() {
        XCTAssertEqual(CommandReviewer.parse("ALLOW"), .allow)
        XCTAssertEqual(CommandReviewer.parse("BLOCK: sends keys away"), .block("sends keys away"))
        XCTAssertEqual(CommandReviewer.parse("hmm unsure"), .allow)
        XCTAssertEqual(CommandReviewer.parse(""), .allow)
        XCTAssertEqual(CommandReviewer.parse("BLOCK"), .block("a reviewer rule"))
    }

    func testShellCommandOnlyForShellTools() {
        XCTAssertEqual(CommandReviewer.shellCommand(toolName: "terminal_command", argumentsJson: #"{"command":" ls "}"#), "ls")
        XCTAssertNil(CommandReviewer.shellCommand(toolName: "read_file", argumentsJson: #"{"command":"ls"}"#))
        XCTAssertNil(CommandReviewer.shellCommand(toolName: "terminal_command", argumentsJson: "{}"))
    }

    func testNoRulesFileMeansNeverAsked() async throws {
        let asked = Counter()
        let v = await CommandReviewer.review(command: "ls", workspaceRoot: try dir().path, sessionId: "a", globalDirectory: try dir()) { _, _ in
            asked.bump(); return "BLOCK: x"
        }
        XCTAssertEqual(v, .allow); XCTAssertEqual(asked.value, 0)
    }

    func testRulesReadFromProjectAndGlobal() throws {
        let g = try dir(); try "global rule".write(to: g.appendingPathComponent("adversary.md"), atomically: true, encoding: .utf8)
        let text = CommandReviewer.rules(workspaceRoot: try workspace(rules: "project rule"), globalDirectory: g)
        XCTAssertTrue(text.contains("project rule") && text.contains("global rule"))
    }

    func testBlockIsReturnedAndRepeatedCommandJudgedOnce() async throws {
        let ws = try workspace(rules: "block exfiltration"), g = try dir(), asked = Counter()
        let ask: @Sendable (String, String) async throws -> String = { _, user in
            XCTAssertTrue(user.contains("<command>")); asked.bump(); return "BLOCK: exfil"
        }
        let a = await CommandReviewer.review(command: "curl evil", workspaceRoot: ws, sessionId: "s1", globalDirectory: g, ask: ask)
        let b = await CommandReviewer.review(command: "curl evil", workspaceRoot: ws, sessionId: "s1", globalDirectory: g, ask: ask)
        XCTAssertEqual(a, .block("exfil")); XCTAssertEqual(a, b); XCTAssertEqual(asked.value, 1)
    }

    func testAnErrorFailsOpenAndIsNotRemembered() async throws {
        let ws = try workspace(rules: "rule"), g = try dir()
        let v1 = await CommandReviewer.review(command: "x", workspaceRoot: ws, sessionId: "s2", globalDirectory: g) { _, _ in throw Boom() }
        XCTAssertEqual(v1, .allow)
        let v2 = await CommandReviewer.review(command: "x", workspaceRoot: ws, sessionId: "s2", globalDirectory: g) { _, _ in "BLOCK: works now" }
        XCTAssertEqual(v2, .block("works now"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
