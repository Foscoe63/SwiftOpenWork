import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Claude needs its thinking blocks back, byte for byte, within a tool-use turn.
final class ThinkingBlockTests: XCTestCase {

    private func run(_ events: [[String: Any]], model: String = "claude-opus-5-5") -> [ThinkingBlock] {
        var capture = ThinkingStreamCapture()
        return events.compactMap { capture.handle($0, modelId: model) }
    }

    private func start(_ type: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "content_block_start", "content_block": ["type": type].merging(extra) { $1 }]
    }
    private func delta(_ type: String, _ key: String, _ value: String) -> [String: Any] {
        ["type": "content_block_delta", "delta": ["type": type, key: value]]
    }
    private let stop: [String: Any] = ["type": "content_block_stop"]

    // MARK: Capture

    func testASummarisedThinkingBlockIsCapturedVerbatim() {
        let blocks = run([
            start("thinking", extra: ["thinking": ""]),
            delta("thinking_delta", "thinking", "Let me "),
            delta("thinking_delta", "thinking", "look."),
            delta("signature_delta", "signature", "EqQBCkYI"),
            stop,
        ])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .thinking)
        XCTAssertEqual(blocks[0].thinking, "Let me look.")
        XCTAssertEqual(blocks[0].signature, "EqQBCkYI")
        XCTAssertEqual(blocks[0].modelId, "claude-opus-5-5")
        XCTAssertTrue(blocks[0].leading)
    }

    func testAnOmittedBlockKeepsItsEmptyTextAndItsSignature() {
        let blocks = run([
            start("thinking"),
            delta("thinking_delta", "thinking", ""),
            delta("signature_delta", "signature", "SIG"),
            stop,
        ])
        XCTAssertEqual(blocks.first?.thinking, "")
        XCTAssertEqual(blocks.first?.signature, "SIG", "the signature is the whole point when text is omitted")
    }

    func testARedactedBlockKeepsItsPayload() {
        let blocks = run([start("redacted_thinking", extra: ["data": "OPAQUE=="]), stop])
        XCTAssertEqual(blocks.first?.kind, .redacted)
        XCTAssertEqual(blocks.first?.data, "OPAQUE==")
    }

    func testSignatureFragmentsAreConcatenatedWithoutTrimming() {
        let blocks = run([start("thinking"), delta("signature_delta", "signature", " AB"), delta("signature_delta", "signature", "CD "), stop])
        XCTAssertEqual(blocks.first?.signature, " ABCD ", "an edited signature is a rejected request")
    }

    func testTextAndToolBlocksProduceNoThinkingBlock() {
        let blocks = run([start("text"), delta("text_delta", "text", "hi"), stop, start("tool_use"), stop])
        XCTAssertTrue(blocks.isEmpty)
    }

    func testAThinkingBlockAfterContentIsFlaggedNotLeading() {
        let blocks = run([
            start("thinking"), delta("signature_delta", "signature", "A"), stop,
            start("text"), stop,
            start("thinking"), delta("signature_delta", "signature", "B"), stop,
        ])
        XCTAssertEqual(blocks.map(\.leading), [true, false])
    }

    func testTwoLeadingBlocksKeepTheirOrder() {
        let blocks = run([
            start("thinking"), delta("signature_delta", "signature", "A"), stop,
            start("redacted_thinking", extra: ["data": "R"]), stop,
        ])
        XCTAssertEqual(blocks.map(\.kind), [.thinking, .redacted])
        XCTAssertTrue(blocks.allSatisfy(\.leading))
    }

    // MARK: Replay

    private func block(_ signature: String = "S", model: String = "claude-opus-5-5", leading: Bool = true) -> ThinkingBlock {
        ThinkingBlock(kind: .thinking, thinking: "t", signature: signature, modelId: model, leading: leading)
    }

    func testABlockIsReplayedExactly() {
        let out = AnthropicRequestPolicy.replayBlocks(for: [block("SIG")], modelId: "claude-opus-5-5")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["type"] as? String, "thinking")
        XCTAssertEqual(out[0]["thinking"] as? String, "t")
        XCTAssertEqual(out[0]["signature"] as? String, "SIG")
        let redacted = AnthropicRequestPolicy.replayBlocks(
            for: [ThinkingBlock(kind: .redacted, data: "D", modelId: "m")], modelId: "m"
        )
        XCTAssertEqual(redacted.first?["type"] as? String, "redacted_thinking")
        XCTAssertEqual(redacted.first?["data"] as? String, "D")
    }

    func testABlockFromAnotherModelIsNeverReplayed() {
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: [block(model: "claude-sonnet-5")], modelId: "claude-opus-5-5").isEmpty)
    }

    func testNonLeadingOrUnsignedBlocksAreNeverReplayed() {
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: [block(leading: false)], modelId: "claude-opus-5-5").isEmpty)
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: [block("")], modelId: "claude-opus-5-5").isEmpty)
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: [ThinkingBlock(kind: .redacted, modelId: "m")], modelId: "m").isEmpty)
    }

    func testOneBadBlockWithdrawsTheWholeSet() {
        let mixed = [block("A"), block("B", leading: false)]
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: mixed, modelId: "claude-opus-5-5").isEmpty, "a partial set would be a modified turn")
    }

    func testNoBlocksReplayNothing() {
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: nil, modelId: "m").isEmpty)
        XCTAssertTrue(AnthropicRequestPolicy.replayBlocks(for: [], modelId: "m").isEmpty)
    }

    func testBlocksOnlyTravelWithARequestThatThinks() {
        func shape(_ id: String, _ effort: ReasoningEffort) -> AnthropicRequestPolicy.Shape {
            AnthropicRequestPolicy.shape(modelId: id, supportsReasoning: true, effort: effort, temperature: 0.7, topP: 1, maxTokens: 8192)
        }
        XCTAssertTrue(AnthropicRequestPolicy.carriesThinking(shape("claude-opus-5-5", .medium), modelId: "claude-opus-5-5"))
        XCTAssertTrue(AnthropicRequestPolicy.carriesThinking(shape("claude-opus-5-5", .off), modelId: "claude-opus-5-5"),
                      "Opus 5.5 cannot switch thinking off, so it still thinks")
        XCTAssertFalse(AnthropicRequestPolicy.carriesThinking(shape("claude-sonnet-5", .off), modelId: "claude-sonnet-5"))
        XCTAssertTrue(AnthropicRequestPolicy.carriesThinking(shape("claude-haiku-4-5", .medium), modelId: "claude-haiku-4-5"))
        XCTAssertFalse(AnthropicRequestPolicy.carriesThinking(shape("claude-haiku-4-5", .off), modelId: "claude-haiku-4-5"))
    }

    // MARK: Persistence

    func testBlocksSurviveASaveAndLoad() throws {
        let original = ChatMessage(role: .assistant, content: "", thinkingBlocks: [block("SIG")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.thinkingBlocks, original.thinkingBlocks)
    }

    func testMessagesSavedBeforeThisExistedStillLoad() throws {
        let old = #"{"id":"m1","sessionId":"s","role":"assistant","content":"hi","timestamp":0}"#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(decoded.thinkingBlocks)
        XCTAssertEqual(decoded.content, "hi")
    }

    func testCollectorKeepsBlocksInOrderAndIsNilWhenEmpty() {
        let collector = AgentThinkingBlockCollector()
        XCTAssertNil(collector.snapshot(), "a message with no thinking must stay exactly as it was")
        collector.add(block("A"))
        collector.add(block("B"))
        XCTAssertEqual(collector.snapshot()?.map(\.signature), ["A", "B"])
    }
}
