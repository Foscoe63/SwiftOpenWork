import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkLocalInference
@testable import SwiftOpenWorkEngine

/// When a cached MLX session may be continued, and when continuing it would be wrong.
final class MLXSessionReuseTests: XCTestCase {

    private func key(model: String = "m", instructions: String = "sys", tools: [String] = ["a"]) -> MLXSessionReuse.Key {
        MLXSessionReuse.Key(modelId: model, instructions: instructions, toolNames: tools)
    }

    private func msg(_ role: String, _ content: String, attachments: Bool = false) -> MLXSessionReuse.Fingerprint {
        MLXSessionReuse.Fingerprint(role: role, content: content, hasAttachments: attachments)
    }

    private func reason(_ d: MLXSessionReuse.Decision) -> String? {
        if case .rebuild(let r) = d { return r }
        return nil
    }

    private func appended(_ d: MLXSessionReuse.Decision) -> [MLXSessionReuse.Fingerprint]? {
        if case .advance(let new) = d { return Array(new) }
        return nil
    }

    // MARK: - Reuse

    func testAppendingContinuesTheSession() {
        let consumed = [msg("system", "sys"), msg("user", "hello"), msg("assistant", "hi")]
        let incoming = consumed + [msg("user", "next question")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: incoming
        )
        XCTAssertEqual(appended(d), [msg("user", "next question")], "only the new message should be prefilled")
    }

    /// The agent-loop case: tool results appended mid-turn, repeatedly.
    func testSeveralToolResultsAppendTogether() {
        let consumed = [msg("user", "do it"), msg("assistant", "calling tools")]
        let incoming = consumed + [msg("user", "[Tool output]\nA"), msg("user", "[Tool output]\nB")]
        XCTAssertEqual(appended(MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: incoming
        ))?.count, 2)
    }

    // MARK: - Rebuild

    func testNoCacheRebuilds() {
        XCTAssertEqual(
            reason(MLXSessionReuse.decide(cachedKey: nil, cachedConsumed: [], incomingKey: key(), incoming: [msg("user", "hi")])),
            "no cached session"
        )
    }

    func testChangedModelRebuilds() {
        let consumed = [msg("user", "hi")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(model: "old"), cachedConsumed: consumed,
            incomingKey: key(model: "new"), incoming: consumed + [msg("user", "more")]
        )
        XCTAssertNotNil(reason(d))
    }

    func testChangedInstructionsRebuild() {
        let consumed = [msg("user", "hi")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(instructions: "a"), cachedConsumed: consumed,
            incomingKey: key(instructions: "b"), incoming: consumed + [msg("user", "more")]
        )
        XCTAssertNotNil(reason(d))
    }

    /// A changed tool list changes what the chat template renders into the prompt.
    func testChangedToolSetRebuilds() {
        let consumed = [msg("user", "hi")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(tools: ["a"]), cachedConsumed: consumed,
            incomingKey: key(tools: ["a", "b"]), incoming: consumed + [msg("user", "more")]
        )
        XCTAssertNotNil(reason(d))
    }

    func testToolOrderDoesNotMatter() {
        let consumed = [msg("user", "hi")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(tools: ["b", "a"]), cachedConsumed: consumed,
            incomingKey: key(tools: ["a", "b"]), incoming: consumed + [msg("user", "more")]
        )
        XCTAssertNotNil(appended(d), "the same tools in a different order is the same session")
    }

    /// The dangerous case: compaction rewrites earlier history. Continuing would let deleted
    /// context keep steering the model with nothing on screen to explain it.
    func testRewrittenHistoryRebuilds() {
        let consumed = [msg("user", "one"), msg("assistant", "two"), msg("user", "three")]
        let compacted = [msg("user", "one"), msg("user", "[Context compacted] …"), msg("user", "three")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: compacted + [msg("user", "four")]
        )
        XCTAssertEqual(reason(d), "history diverged at message 2")
    }

    func testShorterHistoryRebuilds() {
        let consumed = [msg("user", "one"), msg("assistant", "two"), msg("user", "three")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: [msg("user", "one")]
        )
        XCTAssertNotNil(reason(d), "a shorter history is a rewrite and must rebuild")
    }

    /// Re-sending with nothing new would duplicate the last message inside the cache.
    func testNoNewMessagesRebuilds() {
        let consumed = [msg("user", "one"), msg("assistant", "two")]
        let d = MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: consumed
        )
        XCTAssertEqual(reason(d), "no new messages to append")
    }

    func testAttachmentsBlockReuse() {
        let consumed = [msg("user", "one")]
        let incoming = consumed + [msg("user", "look at this", attachments: true)]
        let d = MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: incoming
        )
        XCTAssertNotNil(reason(d))
    }

    func testEmptyConsumedRebuilds() {
        let d = MLXSessionReuse.decide(
            cachedKey: key(), cachedConsumed: [], incomingKey: key(), incoming: [msg("user", "hi")]
        )
        XCTAssertEqual(reason(d), "cached session has consumed nothing")
    }

    /// A trailing edit to the last consumed message is still divergence, not an append.
    func testEditedLastMessageRebuilds() {
        let consumed = [msg("user", "one"), msg("assistant", "two")]
        let incoming = [msg("user", "one"), msg("assistant", "two EDITED"), msg("user", "three")]
        XCTAssertEqual(
            reason(MLXSessionReuse.decide(cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: incoming)),
            "history diverged at message 2"
        )
    }
}

/// A reply the session generated is sent back re-rendered; the position still matches.
extension MLXSessionReuseTests {

    private func generated(_ content: String) -> MLXSessionReuse.Fingerprint {
        MLXSessionReuse.Fingerprint(role: "assistant", content: content, isGeneratedReply: true)
    }

    func testGeneratedReplyMatchesItsSanitisedRendering() {
        let consumed = [
            MLXSessionReuse.Fingerprint(role: "user", content: "do it"),
            generated("<think>hmm</think>calling the tool"),
        ]
        // AgentRunner strips reasoning before putting the message back.
        let incoming = [
            MLXSessionReuse.Fingerprint(role: "user", content: "do it"),
            MLXSessionReuse.Fingerprint(role: "assistant", content: "calling the tool"),
            MLXSessionReuse.Fingerprint(role: "user", content: "[Tool output]\nok"),
        ]
        let d = MLXSessionReuse.decide(
            cachedKey: MLXSessionReuse.Key(modelId: "m", instructions: "sys", toolNames: ["a"]),
            cachedConsumed: consumed,
            incomingKey: MLXSessionReuse.Key(modelId: "m", instructions: "sys", toolNames: ["a"]),
            incoming: incoming
        )
        guard case .advance(let new) = d else {
            return XCTFail("expected reuse, got \(d)")
        }
        XCTAssertEqual(Array(new).count, 1)
    }

    /// A generated reply that is NOT the trailing entry must still match — the skip is scoped
    /// to the session's most recent reply only, so settled history cannot be waved through.
    func testNonTrailingGeneratedReplyStillRequiresAMatch() {
        let consumed = [
            MLXSessionReuse.Fingerprint(role: "user", content: "do it"),
            generated("reply"),
            MLXSessionReuse.Fingerprint(role: "user", content: "settled"),
        ]
        let incoming = [
            MLXSessionReuse.Fingerprint(role: "user", content: "do it"),
            MLXSessionReuse.Fingerprint(role: "user", content: "something else entirely"),
            MLXSessionReuse.Fingerprint(role: "user", content: "settled"),
            MLXSessionReuse.Fingerprint(role: "user", content: "more"),
        ]
        let d = MLXSessionReuse.decide(
            cachedKey: MLXSessionReuse.Key(modelId: "m", instructions: "sys", toolNames: ["a"]),
            cachedConsumed: consumed,
            incomingKey: MLXSessionReuse.Key(modelId: "m", instructions: "sys", toolNames: ["a"]),
            incoming: incoming
        )
        if case .advance = d { XCTFail("a rewrite behind the trailing reply must still rebuild") }
    }
}

/// The session's history and the caller's transcript are not the same list.
extension MLXSessionReuseTests {
    private var k: MLXSessionReuse.Key {
        MLXSessionReuse.Key(modelId: "m", instructions: "sys", toolNames: ["a"])
    }
    private func gen(_ c: String) -> MLXSessionReuse.Fingerprint {
        MLXSessionReuse.Fingerprint(role: "assistant", content: c, isGeneratedReply: true)
    }
    private func plain(_ r: String, _ c: String) -> MLXSessionReuse.Fingerprint {
        MLXSessionReuse.Fingerprint(role: r, content: c)
    }

    /// Observed live: the session held a reply the caller's next list did not carry, which made
    /// the comparison permanently off by one and rebuilt on every iteration.
    func testGeneratedReplyWithNoCounterpartIsSkipped() {
        let consumed = [plain("user", "ask"), plain("assistant", ""), gen("")]
        let incoming = [plain("user", "ask"), plain("assistant", ""), plain("user", "[Tool output]\nx")]
        guard case .advance(let new) = MLXSessionReuse.decide(
            cachedKey: k, cachedConsumed: consumed, incomingKey: k, incoming: incoming
        ) else { return XCTFail("should reuse") }
        XCTAssertEqual(Array(new), [plain("user", "[Tool output]\nx")])
    }

    /// When the caller *does* carry the reply, it matches and is not skipped twice.
    func testGeneratedReplyWithACounterpartConsumesIt() {
        let consumed = [plain("user", "ask"), gen("answer")]
        let incoming = [plain("user", "ask"), plain("assistant", "answer"), plain("user", "next")]
        guard case .advance(let new) = MLXSessionReuse.decide(
            cachedKey: k, cachedConsumed: consumed, incomingKey: k, incoming: incoming
        ) else { return XCTFail("should reuse") }
        XCTAssertEqual(Array(new), [plain("user", "next")], "the reply must not be appended again")
    }

    /// Caller-supplied history being rewritten is still a rebuild — the skip is scoped to
    /// generated replies only.
    func testCallerRewriteStillRebuilds() {
        let consumed = [plain("user", "one"), plain("user", "two"), gen("r")]
        let incoming = [plain("user", "one"), plain("user", "CHANGED"), plain("user", "three")]
        if case .advance = MLXSessionReuse.decide(
            cachedKey: k, cachedConsumed: consumed, incomingKey: k, incoming: incoming
        ) { XCTFail("a rewritten caller message must rebuild") }
    }
}

/// LRU + drop-stale is how NativeMLXService keeps two KV caches, not three.
extension MLXSessionReuseTests {

    private struct Slot: Equatable {
        var id: String
        var conversation: String
    }

    func testRememberDropsTheStaleSessionForTheSameConversation() {
        var list = [Slot(id: "old", conversation: "chat"), Slot(id: "other", conversation: "auto")]
        MLXSessionReuse.remember(
            Slot(id: "rebuilt", conversation: "chat"),
            in: &list,
            maxCount: 2,
            droppingStale: { $0.conversation == "chat" }
        )
        XCTAssertEqual(list.map(\.id), ["rebuilt", "other"])
    }

    func testRememberEvictsTheLeastRecentlyUsedPastTheCap() {
        var list = [Slot(id: "1", conversation: "a"), Slot(id: "2", conversation: "b")]
        MLXSessionReuse.remember(
            Slot(id: "3", conversation: "c"),
            in: &list,
            maxCount: 2,
            droppingStale: { $0.conversation == "c" }
        )
        XCTAssertEqual(list.map(\.id), ["3", "1"], "the oldest slot must go, not the one just used")
    }

    // MARK: - Saying what changed

    func testDivergenceNamesTheFoldedToolResult() {
        let consumed = [msg("user", "fix it"), msg("assistant", ""), msg("user", "[Tool output]\n" + String(repeating: "x", count: 900))]
        let incoming = [msg("user", "fix it"), msg("assistant", ""), msg("user", "[Earlier tool result compacted] xxxx…")]
        let detail = MLXSessionReuse.describeDivergence(consumed: consumed, incoming: incoming)
        XCTAssertEqual(reason(MLXSessionReuse.decide(cachedKey: key(), cachedConsumed: consumed, incomingKey: key(), incoming: incoming)),
                       "history diverged at message 3", "the reason string itself is unchanged")
        XCTAssertTrue(detail?.contains("message 3") ?? false, detail ?? "")
        XCTAssertTrue(detail?.contains("Earlier tool result compacted") ?? false, detail ?? "")
    }

    func testDivergenceReportsARoleChange() {
        let detail = MLXSessionReuse.describeDivergence(consumed: [msg("user", "a")], incoming: [msg("assistant", "a")])
        XCTAssertEqual(detail, "message 1 changed role, from user to assistant")
    }

    func testNoDivergenceDescribesNothing() {
        XCTAssertNil(MLXSessionReuse.describeDivergence(consumed: [msg("user", "a")], incoming: [msg("user", "a"), msg("user", "b")]))
    }
}
