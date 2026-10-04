import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// The "Auto Loop Breaker" detected repetition and then waited for the model to finish anyway: the
/// flag was only read after the stream ended. A real run burned 219 seconds and its whole token
/// budget looping before anything acted on it. Detecting a runaway is not breaking it.
final class LoopBreakerTests: XCTestCase {

    func testDetectsAnExactRepeatingPhrase() {
        let text = String(repeating: "I think the user wants me to call the tool now. ", count: 8)
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: text))
    }

    func testDetectsIdenticalRepeatedLines() {
        let line = "Let me just do what they literally said, which is to call multi_edit.\n"
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: String(repeating: line, count: 6)))
    }

    /// The shape the real run produced: near-identical lines that are not byte-identical.
    func testDetectsNearIdenticalConsecutiveLines() {
        let text = """
        Actually, I think the user is asking me to use multi_edit on Greeter with two edits here.
        Actually, I think the user is asking me to use multi_edit on Greeter with two edits now.
        Actually, I think the user is asking me to use multi_edit on Greeter with two edits again.
        """
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: text))
    }

    func testOrdinaryProseIsNotFlagged() {
        let text = """
        I located the declaration of Greeter in Greeter.swift at line 1. It is a struct with two
        stored properties, greeting and farewell. Next I will replace both string literals in a
        single multi_edit call so that a failure leaves the file untouched rather than half edited.
        Afterwards I will run the tests to confirm nothing else referenced the old values.
        """
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: text))
    }

    func testShortOutputIsNotFlagged() {
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: "ok ok ok"))
    }

    /// The check examines only the tail. Repetition far enough back in a long answer must stop
    /// flagging it — otherwise one early stutter would cut off everything the model said after.
    func testRepetitionOutsideTheTailWindowIsNotFlagged() {
        let early = String(repeating: "same same same same same same same same\n", count: 40)
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: early),
                      "the repetition itself must be detectable, or this test proves nothing")

        // Every token distinct, so nothing in the recent text repeats by any of the checks.
        let sinceThen = (0..<900).map { "w\($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(sinceThen.count, 4000)
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: early + "\n" + sinceThen))
    }

    /// A list of same-shaped bullets is ordinary writing, not a loop. The detector used to flag it
    /// (a 5-word n-gram and a single similar pair were enough), which cut off long answers ending
    /// in a settings list. It now takes an 8-word phrase three times, or three near-identical
    /// lines in a row, so this list survives.
    func testTemplatedListsAreNotFlagged() {
        let list = (0..<6).map { "- Item \($0) describes a distinct configuration value here.\n" }.joined()
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: list))
    }

    /// Loosening that must not let a real spiral through: the same long line again and again.
    func testTheSameSentenceRepeatingIsStillFlagged() {
        let spiral = String(repeating: "Now I have today's date, so let me check the calendar for today.\n", count: 5)
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: spiral))
    }

    /// A model planning a batch of reads lists the same files three times. Real turn, cut off mid-plan.
    func testARepeatedFileListInAPlanIsNotFlagged() {
        let text = """
        I'll load them in batches: the AI service, learning manager, scheduled cleanup manager, notification service, duplicate file finder, large file finder, cleanup result, and test files. Let's start with services and models first.

        I'll keep reading through the codebase to get a grasp of the overall picture. Let me load multiple files in parallel for efficiency. I'll go ahead and read the AI service, learning manager, scheduled cleanup manager, notification service, duplicate file finder, large file finder, cleanup result, and test files. I'll go ahead and read the AI service, learning manager, scheduled cleanup manager, notification service, duplicate file finder, large file finder, cleanup result, and
        """
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: text))
    }

    /// A model drafting an edit quotes the same snippet as "from" and "to". Real turn.
    func testRepeatedCodeInADraftedEditIsNotFlagged() {
        let snippet = "        Text(ByteCountFormatter.string(fromByteCount: visibleFiles.map { $0.size }.reduce(0, +), countStyle: .file))\n"
        let text = "Current code:\n" + snippet + "Change to:\n" + snippet + "Alternatively:\n" + snippet
            + "But note: we are in an HStack, so let's change the HStack to a VStack for the text."
        XCTAssertFalse(AgentStreamAccumulator.detectsRepetitionLoop(in: text))
    }

    /// A long phrase that keeps coming back, with a little variation between lines, is still a loop.
    func testALongPhraseRepeatedManyTimesIsStillFlagged() {
        let phrase = "so I need to read the cleanup engine file again before I can decide what to change next"
        let text = (0..<6).map { "Step \($0): \(phrase) and then continue." }.joined(separator: "\n\n")
        XCTAssertTrue(AgentStreamAccumulator.detectsRepetitionLoop(in: text))
    }

    // MARK: - The gate that keeps the cost bounded

    func testCounterFiresOnlyEveryNthTick() {
        let counter = StreamTickCounter()
        var fired = 0
        for _ in 0..<100 where counter.tick(every: 24) { fired += 1 }
        XCTAssertEqual(fired, 4, "100 tokens at one check per 24")
    }

    func testCounterResetsSoItKeepsFiring() {
        let counter = StreamTickCounter()
        for _ in 0..<23 { XCTAssertFalse(counter.tick(every: 24)) }
        XCTAssertTrue(counter.tick(every: 24))
        XCTAssertFalse(counter.tick(every: 24))
    }
}

/// A turn that produced only reasoning used to render as an empty bubble: `hideTurnNarration`
/// moves a narrated preamble into Reasoning on the assumption a final answer follows, and when the
/// turn ends instead the user is left with silence while the model plainly said something.
@MainActor
final class BlankAnswerRecoveryTests: XCTestCase {

    private func accumulator(onUpdate: @escaping (ChatMessage) -> Void = { _ in }) -> AgentStreamAccumulator {
        AgentStreamAccumulator(
            initialMessage: ChatMessage(sessionId: "s", role: .assistant, content: ""),
            onUpdate: onUpdate
        )
    }

    func testReasoningIsSurfacedWhenNoAnswerWasProduced() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.applyChunk(LLMStreamChunk(deltaReasoning: "I should state plainly that the edit was skipped."))
        acc.finalize()

        let content = final?.content ?? ""
        XCTAssertFalse(content.isEmpty, "silence is the worst of the available outcomes")
        XCTAssertTrue(content.contains("skipped"))
        XCTAssertTrue(content.lowercased().contains("only its own reasoning"),
                      "the user must be told this is reasoning, not a considered answer")
    }

    func testARealAnswerIsLeftAlone() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.applyChunk(LLMStreamChunk(deltaReasoning: "thinking about it"))
        acc.applyChunk(LLMStreamChunk(deltaText: "I replaced both string literals."))
        acc.finalize()

        XCTAssertEqual(final?.content, "I replaced both string literals.")
    }

    /// Originally this pinned "stay blank when there is nothing to surface". A real export showed
    /// that case is reachable and unhelpful: the user asked "Good Day", got three identical date
    /// lookups and then nothing, and an empty bubble cannot be told apart from a broken app. It
    /// now reports which happened — a statement of fact, not invented content.
    func testABlankTurnSaysSoRatherThanRenderingNothing() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.finalize()

        let content = final?.content ?? ""
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(content.contains("without producing any output"))
    }

    func testABlankTurnThatRanToolsPointsAtTheResults() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.addToolCall(ToolCallInfo(
            id: "t1", toolName: "get_current_date", argumentsJson: "{}", status: .success
        ))
        acc.finalize()

        XCTAssertTrue(final?.content.contains("ran tools") == true)
    }

    /// The error path states its own case; adding a second explanation would contradict it.
    func testAnErroredTurnIsLeftToTheErrorPath() {
        var final: ChatMessage?
        let acc = accumulator { final = $0 }
        acc.handleError(NSError(domain: "t", code: 1))
        acc.finalize()

        XCTAssertEqual(final?.content ?? "", "")
        XCTAssertTrue(final?.isError == true)
    }
}
