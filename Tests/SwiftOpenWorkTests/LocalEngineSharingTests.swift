import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkLocalInference
@testable import SwiftOpenWorkEngine

/// The in-process engine is one model shared by everything that can start a turn: the chat
/// window, scheduled automations, Shortcuts, and sub-agents running in parallel.
final class LocalGenerationGateTests: XCTestCase {

    /// Order of arrival is order of service, and nobody overlaps.
    func testGenerationsRunOneAtATimeInArrivalOrder() async throws {
        let gate = LocalGenerationGate()
        let first = try await gate.acquire(label: "first")

        let order = OrderRecorder()
        let second = Task {
            let ticket = try await gate.acquire(label: "second")
            await order.append("second")
            await gate.release(ticket)
        }
        // Give the second waiter time to queue before the third arrives.
        try await waitUntil { await gate.queueLength == 1 }
        let third = Task {
            let ticket = try await gate.acquire(label: "third")
            await order.append("third")
            await gate.release(ticket)
        }
        try await waitUntil { await gate.queueLength == 2 }

        let holderWhileQueued = await gate.currentHolder
        XCTAssertEqual(holderWhileQueued, "first")
        await order.append("first")
        await gate.release(first)

        try await second.value
        try await third.value
        let recorded = await order.values
        XCTAssertEqual(recorded, ["first", "second", "third"])
        let holderAfter = await gate.currentHolder
        XCTAssertNil(holderAfter, "the engine is free once everyone has released")
    }

    /// The waiting turn must be told who it is waiting for — otherwise a queued turn is
    /// indistinguishable from a hung one.
    func testAWaiterIsToldWhoHoldsTheEngine() async throws {
        let gate = LocalGenerationGate()
        let held = try await gate.acquire(label: "background run “Morning Brief”")
        let heard = OrderRecorder()
        let waiter = Task {
            let ticket = try await gate.acquire(label: "a chat turn") { holder in
                Task { await heard.append(holder) }
            }
            await gate.release(ticket)
        }
        try await waitUntil { await gate.queueLength == 1 }
        await gate.release(held)
        try await waiter.value
        try await waitUntil { await heard.values.count == 1 }
        let values = await heard.values
        XCTAssertEqual(values, ["background run “Morning Brief”"])
        XCTAssertTrue(LocalGenerationGate.waitingNotice(behind: values[0]).contains("Morning Brief"))
    }

    /// An uncontended acquire must not announce a wait that never happened.
    func testNoWaitNoNotice() async throws {
        let gate = LocalGenerationGate()
        let heard = OrderRecorder()
        let ticket = try await gate.acquire(label: "solo") { holder in
            Task { await heard.append(holder) }
        }
        await gate.release(ticket)
        try await Task.sleep(nanoseconds: 50_000_000)
        let values = await heard.values
        XCTAssertTrue(values.isEmpty)
    }

    /// Stop pressed while queued must leave the queue, not start a generation later.
    func testCancellingAWaiterRemovesItFromTheQueue() async throws {
        let gate = LocalGenerationGate()
        let held = try await gate.acquire(label: "holder")
        let waiter = Task {
            _ = try await gate.acquire(label: "cancelled")
        }
        try await waitUntil { await gate.queueLength == 1 }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
        }
        try await waitUntil { await gate.queueLength == 0 }
        await gate.release(held)
        let holder = await gate.currentHolder
        XCTAssertNil(holder, "the cancelled waiter must not have been handed the engine")
    }

    /// A second release of the same ticket must not hand the engine to two generations.
    func testDoubleReleaseIsHarmless() async throws {
        let gate = LocalGenerationGate()
        let a = try await gate.acquire(label: "a")
        await gate.release(a)
        let b = try await gate.acquire(label: "b")
        await gate.release(a)
        let holder = await gate.currentHolder
        XCTAssertEqual(holder, "b")
        await gate.release(b)
    }

    /// A sub-agent's deadline excludes time queued behind a sibling, so the wait must be measured
    /// — including while it is still going on, which is when the watchdog asks.
    func testTimeQueuedIsRecordedOnTheWaitClock() async throws {
        let gate = LocalGenerationGate()
        let clock = LocalGenerationGate.WaitClock()
        let held = try await gate.acquire(label: "sibling")
        let waiter = Task {
            try await LocalGenerationGate.$waitClock.withValue(clock) {
                try await gate.acquire(label: "sub-agent")
            }
        }
        try await waitUntil { await gate.queueLength == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(clock.seconds, 0.15, "a wait in progress counts")
        await gate.release(held)
        let ticket = try await waiter.value
        let waited = clock.seconds
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(clock.seconds, waited, accuracy: 0.001, "the clock stops once the engine is handed over")
        await gate.release(ticket)
    }

    /// An uncontended acquire adds nothing to the clock.
    func testNoWaitNoWaitTime() async throws {
        let gate = LocalGenerationGate()
        let clock = LocalGenerationGate.WaitClock()
        let ticket = try await LocalGenerationGate.$waitClock.withValue(clock) {
            try await gate.acquire(label: "solo")
        }
        await gate.release(ticket)
        XCTAssertEqual(clock.seconds, 0)
    }

    // MARK: - Helpers

    private actor OrderRecorder {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

/// Which cached session a turn continues, now that more than one is kept.
final class MLXSessionSelectionTests: XCTestCase {

    private func key(_ instructions: String, tools: [String] = ["a"]) -> MLXSessionReuse.Key {
        MLXSessionReuse.Key(modelId: "m", instructions: instructions, toolNames: tools)
    }

    private func fp(_ role: String, _ content: String, generated: Bool = false) -> MLXSessionReuse.Fingerprint {
        MLXSessionReuse.Fingerprint(role: role, content: content, isGeneratedReply: generated)
    }

    /// A chat and an automation taking turns each keep their own cache.
    func testTheMatchingConversationIsContinuedWhereverItSits() {
        let chat = MLXSessionReuse.Candidate(
            key: key("chat system"),
            consumed: [fp("user", "hello"), fp("assistant", "hi", generated: true)]
        )
        let automation = MLXSessionReuse.Candidate(
            key: key("automation system"),
            consumed: [fp("user", "brief me"), fp("assistant", "ok", generated: true)]
        )
        let result = MLXSessionReuse.select(
            candidates: [automation, chat],
            incomingKey: key("chat system"),
            incoming: [fp("user", "hello"), fp("assistant", "hi"), fp("user", "next")]
        )
        XCTAssertEqual(result.index, 1, "the chat's cache sits second and must still be found")
        guard case .advance(let new) = result.decision else {
            return XCTFail("expected to continue, got \(result.decision)")
        }
        XCTAssertEqual(Array(new), [fp("user", "next")])
    }

    /// A conversation none of the caches belongs to is new, not a reset. Saying "Context cache
    /// reset" for it told the user something had been lost when nothing had.
    func testAnUnrelatedConversationIsNotReportedAsAReset() {
        let other = MLXSessionReuse.Candidate(key: key("someone else"), consumed: [fp("user", "x")])
        let result = MLXSessionReuse.select(
            candidates: [other],
            incomingKey: key("mine"),
            incoming: [fp("user", "hello")]
        )
        XCTAssertNil(result.index)
        XCTAssertEqual(result.decision, .rebuild(reason: "no cached session"))
    }

    /// The same conversation whose history really was rewritten still says so.
    func testTheSameConversationDivergingStillReportsWhy() {
        let mine = MLXSessionReuse.Candidate(
            key: key("mine"),
            consumed: [fp("user", "original"), fp("assistant", "a", generated: true)]
        )
        let result = MLXSessionReuse.select(
            candidates: [mine],
            incomingKey: key("mine"),
            incoming: [fp("user", "compacted summary"), fp("user", "next")]
        )
        XCTAssertNil(result.index)
        guard case .rebuild(let reason) = result.decision else { return XCTFail() }
        XCTAssertTrue(reason.contains("diverged"), reason)
    }

    /// Catalog promotion changes the tool set mid-conversation. That is a real reset.
    func testAChangedToolSetInTheSameConversationIsReported() {
        let mine = MLXSessionReuse.Candidate(key: key("mine", tools: ["a"]), consumed: [fp("user", "x")])
        let result = MLXSessionReuse.select(
            candidates: [mine],
            incomingKey: key("mine", tools: ["a", "b"]),
            incoming: [fp("user", "x"), fp("user", "y")]
        )
        guard case .rebuild(let reason) = result.decision else { return XCTFail() }
        XCTAssertNotEqual(reason, "no cached session")
    }
}

/// The system prompt must be in view once, however long the conversation runs.
final class SystemPromptIsRenderedOnceTests: XCTestCase {

    func testTheSystemPromptLeadsTheHistory() {
        XCTAssertEqual(
            MLXSessionReuse.sessionHistory(system: "SYS", earlierMessages: ["u1", "a1"]),
            ["SYS", "u1", "a1"]
        )
        XCTAssertEqual(MLXSessionReuse.sessionHistory(system: nil as String?, earlierMessages: ["u1"]), ["u1"])
    }

    /// `ChatSession` re-sends `instructions` on every call, even when continuing a KV cache —
    /// measured, turn two of a conversation prefilled the whole 498-token system prompt again.
    /// The engine must never hand the system prompt over that way.
    func testTheEngineNeverPassesInstructionsToChatSession() throws {
        let source = try String(contentsOf: SourceTree.url("Engine/Providers/NativeMLXService.swift"), encoding: .utf8)
        let calls = source.components(separatedBy: "ChatSession(").dropFirst()
        XCTAssertFalse(calls.isEmpty, "expected to find the ChatSession construction")
        for call in calls {
            let arguments = call.prefix(while: { $0 != ")" })
            XCTAssertFalse(arguments.contains("instructions:"),
                           "ChatSession(instructions:) re-prefills the system prompt on every continued turn")
        }
    }

    /// What the context meter shows for a continued session is the whole window in use, not the
    /// handful of tokens the latest message added.
    func testContextTokensIncludeTheCachedPrefix() {
        XCTAssertEqual(MLXSessionReuse.contextTokens(cachedBefore: 510, prefilled: 14), 524)
        XCTAssertEqual(MLXSessionReuse.contextTokens(cachedBefore: 0, prefilled: 498), 498)
        XCTAssertEqual(MLXSessionReuse.contextTokens(cachedBefore: -3, prefilled: 5), 5)
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }
}

/// A run the window did not start used to leave the header reading "Agent ready" while it held
/// the local model, so a chat turn queued behind it looked hung.
final class BackgroundRunStatusTests: XCTestCase {

    func testTheHeaderNamesABackgroundRun() {
        XCTAssertEqual(BackgroundRun.statusLine(chatIsGenerating: false, runs: []), "Agent ready")
        let line = BackgroundRun.statusLine(
            chatIsGenerating: false,
            runs: [BackgroundRun(sessionId: "s", title: "Morning Brief")]
        )
        XCTAssertTrue(line.contains("Morning Brief"), line)
        XCTAssertTrue(line.contains("background"), line)
    }

    func testSeveralRunsAreCounted() {
        let line = BackgroundRun.statusLine(
            chatIsGenerating: true,
            runs: [BackgroundRun(sessionId: "a", title: "A"), BackgroundRun(sessionId: "b", title: "B")]
        )
        XCTAssertTrue(line.hasPrefix("Agent executing..."), line)
        XCTAssertTrue(line.contains("+1 more"), line)
    }
}

/// Multimodal checkpoints declare their window one level down.
final class DeclaredContextWindowTests: XCTestCase {

    func testTopLevelIsRead() {
        XCTAssertEqual(LocalMLXEngine.declaredContextWindow(config: ["max_position_embeddings": 131_072]), 131_072)
    }

    /// Ornith-1.5-35B's real shape: nothing at the top, 262,144 under `text_config`.
    func testTextConfigIsRead() {
        let ornith: [String: Any] = [
            "model_type": "qwen3_5_moe",
            "vision_config": ["depth": 27],
            "text_config": ["max_position_embeddings": 262_144],
        ]
        XCTAssertEqual(LocalMLXEngine.declaredContextWindow(config: ornith), 262_144)
    }

    func testNothingDeclaredIsNil() {
        XCTAssertNil(LocalMLXEngine.declaredContextWindow(config: ["model_type": "x"]))
        XCTAssertNil(LocalMLXEngine.declaredContextWindow(config: ["max_position_embeddings": 0]))
    }
}

final class GenerationSpeedLabelTests: XCTestCase {
    @MainActor
    func testSpeedIsShownOnlyWhenMeasuredAndFinished() {
        var message = ChatMessage(role: .assistant, content: "hi")
        XCTAssertNil(MessageBubbleView.speedLabel(message))
        message.generationTokensPerSecond = 41.6
        XCTAssertEqual(MessageBubbleView.speedLabel(message), "42 tok/s")
        message.generationTokensPerSecond = 3.25
        XCTAssertEqual(MessageBubbleView.speedLabel(message), "3.2 tok/s")
        message.isStreaming = true
        XCTAssertNil(MessageBubbleView.speedLabel(message))
    }

    func testSpeedSurvivesARelaunch() throws {
        var message = ChatMessage(role: .assistant, content: "hi")
        message.generationTokensPerSecond = 55
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.generationTokensPerSecond, 55)
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"assistant","content":"x"}"#.utf8))
        XCTAssertNil(legacy.generationTokensPerSecond)
    }
}
