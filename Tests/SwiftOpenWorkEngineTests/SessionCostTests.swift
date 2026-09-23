import XCTest
@testable import SwiftOpenWorkCore

/// `recordActivity(providers:)` is the only place `Session.estimatedCost` is set. Before this it
/// was either left at zero forever, or (in the dashboard) guessed from a character count priced
/// at one flat rate regardless of provider — a local, free session and an expensive cloud one
/// reported the same "cost" per token. This prices the session's own recorded token counts against
/// its own model's own real per-1k rates.
final class SessionCostTests: XCTestCase {

    private func provider(id: String, modelId: String, costPerKPrompt: Double, costPerKCompletion: Double) -> ModelProvider {
        ModelProvider(
            id: id,
            name: id,
            type: .cloud,
            kind: .anthropic,
            models: [
                ModelInfo(
                    id: modelId,
                    name: modelId,
                    providerId: id,
                    costPer1kPrompt: costPerKPrompt,
                    costPer1kCompletion: costPerKCompletion
                )
            ]
        )
    }

    func testCostIsPricedFromTheSessionsOwnModel() {
        var session = Session(providerId: "anthropic-cloud", modelId: "claude-x")
        session.messages = [
            ChatMessage(sessionId: session.id, role: .user, content: "hi", promptTokens: 1000, completionTokens: 0),
            ChatMessage(sessionId: session.id, role: .assistant, content: "hello", promptTokens: 0, completionTokens: 2000)
        ]
        let providers = [provider(id: "anthropic-cloud", modelId: "claude-x", costPerKPrompt: 0.003, costPerKCompletion: 0.015)]

        session.recordActivity(providers: providers)

        XCTAssertEqual(session.totalPromptTokens, 1000)
        XCTAssertEqual(session.totalCompletionTokens, 2000)
        // 1000/1000 * 0.003 + 2000/1000 * 0.015 = 0.003 + 0.030
        XCTAssertEqual(session.estimatedCost, 0.033, accuracy: 0.0001)
    }

    func testALocalModelWithNoPriceCostsNothing() {
        var session = Session(providerId: "local-mlx", modelId: "on-device")
        session.messages = [
            ChatMessage(sessionId: session.id, role: .assistant, content: "hello", promptTokens: 500, completionTokens: 500)
        ]
        // No pricing for this model at all — its cost is zero, not a guess.
        let providers = [provider(id: "local-mlx", modelId: "on-device", costPerKPrompt: 0, costPerKCompletion: 0)]

        session.recordActivity(providers: providers)

        XCTAssertEqual(session.estimatedCost, 0)
    }

    func testAnUnknownModelLeavesCostUnchangedRatherThanGuessing() {
        var session = Session(providerId: "anthropic-cloud", modelId: "claude-x")
        session.estimatedCost = 1.5 // set by a previous, successful lookup
        session.messages = [
            ChatMessage(sessionId: session.id, role: .assistant, content: "hello", promptTokens: 100, completionTokens: 100)
        ]

        // The provider catalog no longer has this model (deleted, or not loaded yet) — do not
        // silently reset a real cost to zero on a lookup miss.
        session.recordActivity(providers: [])

        XCTAssertEqual(session.estimatedCost, 1.5)
    }

    func testCallingWithNoProvidersDefaultLeavesCostAlone() {
        var session = Session(providerId: "anthropic-cloud", modelId: "claude-x")
        session.estimatedCost = 2.0
        session.messages = [
            ChatMessage(sessionId: session.id, role: .assistant, content: "hello", promptTokens: 100, completionTokens: 100)
        ]

        // Callers that only need updatedAt / token totals (the default `providers: []`) must not
        // clobber a cost a previous, provider-aware call already computed.
        session.recordActivity()

        XCTAssertEqual(session.totalPromptTokens, 100)
        XCTAssertEqual(session.estimatedCost, 2.0)
    }
}
