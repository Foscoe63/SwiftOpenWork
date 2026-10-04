import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

final class CodeIndexTests: XCTestCase {

    private func makeRepo() throws -> String {
        let root = NSTemporaryDirectory() + "index-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        try """
        import Foundation
        /// Validates a user's password against the stored hash.
        func authenticateUser(password: String) -> Bool { return true }
        """.write(toFile: root + "/Sources/Auth.swift", atomically: true, encoding: .utf8)
        try """
        import Foundation
        func renderInvoiceTotal(amount: Double) -> String { return "$\\(amount)" }
        """.write(toFile: root + "/Sources/Invoice.swift", atomically: true, encoding: .utf8)
        try "binary-ish".write(toFile: root + "/Sources/data.bin", atomically: true, encoding: .utf8)
        return root
    }

    // MARK: - Tokenisation

    /// camelCase and snake_case must yield the same terms, or a query in one style misses the other.
    func testTokenizerSplitsBothIdentifierStyles() {
        XCTAssertEqual(CodeIndex.tokenize("parseToolCall"), ["parse", "tool", "call"])
        XCTAssertEqual(CodeIndex.tokenize("parse_tool_call"), ["parse", "tool", "call"])
    }

    func testTokenizerDropsSingleCharactersAndPunctuation() {
        XCTAssertEqual(CodeIndex.tokenize("let x = foo(1)"), ["let", "foo"])
    }

    // MARK: - Chunking

    func testChunkingCoversEveryLineWithNumbers() {
        let content = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let chunks = CodeIndex.chunk(path: "a.swift", content: content)
        XCTAssertEqual(chunks.first?.startLine, 1)
        XCTAssertEqual(chunks.last?.endLine, 100)
        // Contiguous, no gaps.
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(b.startLine, a.endLine + 1)
        }
    }

    func testBlankChunksAreSkipped() {
        let chunks = CodeIndex.chunk(path: "a.swift", content: "\n\n\n")
        XCTAssertTrue(chunks.isEmpty)
    }

    func testOnlyTextExtensionsAreIndexed() {
        XCTAssertTrue(CodeIndex.isTextExtension("swift"))
        XCTAssertTrue(CodeIndex.isTextExtension("md"))
        XCTAssertFalse(CodeIndex.isTextExtension("png"))
        XCTAssertFalse(CodeIndex.isTextExtension("bin"))
    }

    // MARK: - Search

    func testFindsTheRelevantFile() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let hits = await CodeIndex.shared.search(query: "authenticate password", root: root)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.chunk.path, "Sources/Auth.swift")
    }

    /// BM25's point: a term common to every chunk must not outrank a distinguishing one.
    func testCommonTermsDoNotDominate() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // "import Foundation" appears in both files; "invoice" only in one.
        let hits = await CodeIndex.shared.search(query: "import invoice", root: root)
        XCTAssertEqual(hits.first?.chunk.path, "Sources/Invoice.swift")
    }

    func testResultsCarryLineRanges() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let hits = await CodeIndex.shared.search(query: "authenticate", root: root)
        let chunk = try XCTUnwrap(hits.first?.chunk)
        XCTAssertGreaterThan(chunk.endLine, 0)
        XCTAssertLessThanOrEqual(chunk.startLine, chunk.endLine)
    }

    func testUnmatchedQueryPointsAtGrep() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let hits = await CodeIndex.shared.search(query: "zzzzqqq", root: root)
        XCTAssertTrue(CodeIndex.format(hits, query: "zzzzqqq").contains("grep"))
    }

    func testRebuildReusesUnchangedFiles() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let first = await CodeIndex.shared.build(root: root)
        let second = await CodeIndex.shared.build(root: root)
        XCTAssertEqual(first, second, "an unchanged tree should index to the same chunk count")
        XCTAssertGreaterThan(first, 0)
    }

    func testNewFileIsPickedUpOnRebuild() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }

        _ = await CodeIndex.shared.build(root: root)
        try "func brandNewSymbol() {}".write(toFile: root + "/Sources/New.swift", atomically: true, encoding: .utf8)
        _ = await CodeIndex.shared.build(root: root)

        let hits = await CodeIndex.shared.search(query: "brand new symbol", root: root)
        XCTAssertEqual(hits.first?.chunk.path, "Sources/New.swift")
    }
}

final class ContextCompactionTests: XCTestCase {

    private func toolCall(_ name: String, _ args: [String: Any], failed: Bool = false, error: String? = nil) -> ToolCallInfo {
        ToolCallInfo(
            toolName: name,
            argumentsJson: String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!,
            status: failed ? .error : .success,
            errorMessage: error
        )
    }

    private func assistant(_ calls: [ToolCallInfo]) -> ChatMessage {
        ChatMessage(sessionId: "s", role: .assistant, content: "working", toolCalls: calls)
    }

    // MARK: - Digest

    func testDigestRecordsFileWorkByCategory() {
        let messages = [
            assistant([toolCall("edit_file", ["path": "/repo/Sources/A.swift"])]),
            assistant([toolCall("file_write", ["path": "/repo/Sources/B.swift"])]),
            assistant([toolCall("file_delete", ["path": "/repo/Old.swift"])]),
        ]
        let digest = ContextCompactor.digest(of: messages)
        XCTAssertEqual(digest.filesEdited, ["A.swift"])
        XCTAssertEqual(digest.filesWritten, ["B.swift"])
        XCTAssertEqual(digest.filesDeleted, ["Old.swift"])
    }

    func testDigestRecordsCommandsAndMarksFailures() {
        let messages = [
            assistant([toolCall("terminal_command", ["command": "swift build"])]),
            assistant([toolCall("run_tests", ["command": "swift test"], failed: true)]),
        ]
        let rendered = ContextCompactor.digest(of: messages).rendered()
        XCTAssertTrue(rendered.contains("swift build"))
        XCTAssertTrue(rendered.contains("swift test (failed)"))
    }

    func testDigestRemembersWhyACallFailed() {
        let messages = [assistant([toolCall("edit_file", ["path": "/r/A.swift"], failed: true, error: "old_string not found")])]
        XCTAssertTrue(ContextCompactor.digest(of: messages).rendered().contains("old_string not found"))
    }

    func testDigestDeduplicatesRepeatedEdits() {
        let messages = [
            assistant([toolCall("edit_file", ["path": "/r/A.swift"])]),
            assistant([toolCall("edit_file", ["path": "/r/A.swift"])]),
        ]
        XCTAssertEqual(ContextCompactor.digest(of: messages).filesEdited, ["A.swift"])
    }

    func testEmptyDigestRendersNothing() {
        XCTAssertTrue(ContextCompactor.digest(of: []).isEmpty)
        XCTAssertEqual(ContextCompactor.digest(of: []).rendered(), "")
    }

    // MARK: - Compaction

    private func longConversation(_ count: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            ChatMessage(sessionId: "s", role: .user, content: "Refactor the MCP layer")
        ]
        for i in 0..<count {
            messages.append(assistant([toolCall("edit_file", ["path": "/repo/File\(i).swift"])]))
            messages.append(ChatMessage(
                sessionId: "s", role: .tool,
                content: String(repeating: "output ", count: 400)
            ))
        }
        return messages
    }

    func testBelowThresholdIsUntouched() {
        let messages = longConversation(1)
        let (out, did) = ContextCompactor.compactIfNeeded(messages, thresholdTokens: 1_000_000)
        XCTAssertFalse(did)
        XCTAssertEqual(out.count, messages.count)
    }

    func testCompactionKeepsTheOriginalTask() {
        let (out, did) = ContextCompactor.compactIfNeeded(longConversation(30), thresholdTokens: 500)
        XCTAssertTrue(did)
        XCTAssertTrue(out.first?.content.contains("Refactor the MCP layer") == true,
                      "losing the task is how an agent finishes the wrong thing")
    }

    /// The regression this rewrite exists to prevent: compaction erasing the record of the work.
    func testCompactionPreservesWhatTheDroppedTurnsDid() {
        let (out, did) = ContextCompactor.compactIfNeeded(longConversation(30), thresholdTokens: 500)
        XCTAssertTrue(did)
        let text = out.first { $0.content.contains("[Context compacted]") }?.content ?? ""
        XCTAssertTrue(text.contains("edited:"), "the digest should survive compaction")
        XCTAssertTrue(text.contains("File0.swift"))
        XCTAssertTrue(text.contains("Do not redo this work"))
    }

    func testCompactionKeepsRecentMessages() {
        let messages = longConversation(30)
        let (out, _) = ContextCompactor.compactIfNeeded(messages, thresholdTokens: 500, keepRecent: 6)
        XCTAssertEqual(out.suffix(6).map(\.content), messages.suffix(6).map(\.content))
        XCTAssertLessThan(out.count, messages.count)
    }

    // MARK: - Tool folding

    func testFoldingKeepsRecentToolResultsIntact() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(ChatMessage(
                sessionId: "s", role: .tool,
                content: String(repeating: "x", count: 900) + "\(i)"
            ))
        }
        let folded = ContextCompactor.foldOldToolResults(messages, keepLast: 3)
        XCTAssertTrue(folded[0].content.contains("compacted"))
        XCTAssertFalse(folded[9].content.contains("compacted"))
    }

    func testShortToolResultsAreNeverFolded() {
        let messages = (0..<10).map { ChatMessage(sessionId: "s", role: .tool, content: "short \($0)") }
        let folded = ContextCompactor.foldOldToolResults(messages, keepLast: 2)
        XCTAssertFalse(folded.contains { $0.content.contains("compacted") })
    }
}

final class ManualCompactionAndMeterTests: XCTestCase {
    private func history(turns: Int) -> [ChatMessage] {
        var out = [ChatMessage(sessionId: "s", role: .user, content: "the task")]
        for i in 0..<turns {
            out.append(ChatMessage(sessionId: "s", role: .assistant, content: "step \(i)"))
            out.append(ChatMessage(sessionId: "s", role: .tool, content: String(repeating: "x", count: 6_000)))
        }
        return out
    }

    func testCompactNowShrinksALongHistoryAndKeepsTheTask() {
        let messages = history(turns: 20)
        let result = ContextCompactor.compactNow(messages)
        XCTAssertTrue(result.didCompact)
        XCTAssertLessThan(result.tokensAfter, result.tokensBefore / 4)
        XCTAssertEqual(result.messages.first?.content, "the task")
        XCTAssertTrue(result.messages.contains { $0.content.contains("[Context compacted]") })
    }

    func testCompactNowLeavesAShortHistoryAlone() {
        let messages = [ChatMessage(sessionId: "s", role: .user, content: "hi"),
                        ChatMessage(sessionId: "s", role: .assistant, content: "hello")]
        XCTAssertFalse(ContextCompactor.compactNow(messages).didCompact)
    }

    /// 440k reported against a 262k window, from a chat holding a fraction of that.
    func testMeterFallsBackToAnEstimateWhenTheReportExceedsTheWindow() {
        var reply = ChatMessage(sessionId: "s", role: .assistant, content: "done")
        reply.promptTokens = 439_594
        var session = Session()
        session.messages = [ChatMessage(sessionId: "s", role: .user, content: "go"), reply]
        let meter = ContextMeter.forSession(session, contextWindow: 262_000)
        XCTAssertEqual(meter?.isEstimate, true)
        XCTAssertLessThan(meter?.used ?? .max, 262_000)
        XCTAssertTrue(meter?.label.hasPrefix("~") ?? false)
    }

    func testMeterKeepsAPlausibleProviderFigure() {
        var reply = ChatMessage(sessionId: "s", role: .assistant, content: String(repeating: "y", count: 90_000))
        reply.promptTokens = 40_000
        var session = Session()
        session.messages = [ChatMessage(sessionId: "s", role: .user, content: "go"), reply]
        let meter = ContextMeter.forSession(session, contextWindow: 262_000)
        XCTAssertEqual(meter?.isEstimate, false)
        XCTAssertEqual(meter?.used, 40_000)
    }
}
