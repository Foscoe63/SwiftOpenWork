import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// A request shaped for the wrong generation is a 400, so the shape is pinned per model.
final class AnthropicRequestPolicyTests: XCTestCase {

    private func shape(_ id: String, effort: ReasoningEffort = .medium, maxTokens: Int = 8192) -> AnthropicRequestPolicy.Shape {
        AnthropicRequestPolicy.shape(modelId: id, supportsReasoning: true, effort: effort, temperature: 0.7, topP: 0.9, maxTokens: maxTokens)
    }

    func testCurrentModelsNeverGetManualThinkingOrSampling() {
        for id in ["claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1", "claude-opus-4-8"] {
            let s = shape(id)
            XCTAssertEqual(s.thinking?["type"] as? String, "adaptive", "\(id): `enabled` + budget_tokens is not accepted")
            XCTAssertEqual(s.thinking?["display"] as? String, "summarized", id)
            XCTAssertNil(s.thinking?["budget_tokens"], id)
            XCTAssertNil(s.temperature, "\(id): a non-default temperature is a 400")
            XCTAssertNil(s.topP, "\(id): so is top_p")
            XCTAssertEqual(s.outputConfig?["effort"] as? String, "medium", id)
        }
    }

    func testEffortIsPassedThrough() {
        XCTAssertEqual(shape("claude-opus-5-5", effort: .high).outputConfig?["effort"] as? String, "high")
        XCTAssertEqual(shape("claude-opus-5-5", effort: .low).outputConfig?["effort"] as? String, "low")
    }

    func testOnlySonnet5CanHaveThinkingDisabled() {
        XCTAssertEqual(shape("claude-sonnet-5", effort: .off).thinking?["type"] as? String, "disabled")
        for id in ["claude-opus-5-5", "claude-fable-5-1"] {
            let s = shape(id, effort: .off)
            XCTAssertNil(s.thinking, "\(id) rejects thinking: disabled")
            XCTAssertEqual(s.outputConfig?["effort"] as? String, "low", id)
        }
    }

    func testHaikuKeepsExtendedThinking() {
        let s = shape("claude-haiku-4-5-20251001", effort: .medium)
        XCTAssertEqual(s.thinking?["type"] as? String, "enabled")
        XCTAssertEqual(s.thinking?["budget_tokens"] as? Int, 2048)
        XCTAssertNil(s.temperature, "extended thinking requires the default temperature")
        XCTAssertNil(s.outputConfig)
    }

    func testTheThinkingBudgetStaysBelowMaxTokens() {
        XCTAssertEqual(shape("claude-haiku-4-5", effort: .high, maxTokens: 3000).thinking?["budget_tokens"] as? Int, 1976)
        let tiny = shape("claude-haiku-4-5", effort: .high, maxTokens: 1500)
        XCTAssertNil(tiny.thinking, "no room for both thinking and an answer: skip thinking rather than fail")
        XCTAssertEqual(tiny.temperature, 0.7)
    }

    func testWithoutThinkingOlderModelsKeepTheirSampling() {
        let s = shape("claude-haiku-4-5", effort: .off)
        XCTAssertNil(s.thinking)
        XCTAssertEqual(s.temperature, 0.7)
        XCTAssertEqual(s.topP, 0.9)
    }

    func testFamilyMatchingRespectsTheBoundary() {
        XCTAssertTrue(AnthropicRequestPolicy.isAdaptiveOnly("claude-opus-4-7"))
        XCTAssertFalse(AnthropicRequestPolicy.isAdaptiveOnly("claude-opus-4-6"), "4.6 still accepts budget_tokens")
        XCTAssertFalse(AnthropicRequestPolicy.isAdaptiveOnly("claude-sonnet-4-6"))
        XCTAssertFalse(AnthropicRequestPolicy.isAdaptiveOnly("claude-haiku-4-5"))
    }
}
