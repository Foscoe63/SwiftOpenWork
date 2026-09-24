import Foundation
import SwiftOpenWorkCore

/// Which thinking, effort and sampling parameters a Claude model will accept.
///
/// Anthropic changed the rules with the 4.7 generation, and a request that follows the old ones is
/// answered with a 400 rather than ignored:
///
/// * **Thinking is on by default** (adaptive) on Sonnet 5, Opus 5.5, Fable 5.1 and their
///   siblings. `thinking: {type: "enabled", budget_tokens: N}` — what this app always sent — is
///   not accepted on them. Depth is set with `output_config.effort` instead.
/// * **Sampling parameters are fixed.** A non-default `temperature`, `top_p` or `top_k` is a 400
///   on every request, thinking or not. The app sent `temperature` on every non-thinking one.
/// * `thinking: {type: "disabled"}` is rejected by Opus 5.5 and Fable 5.1, and accepted by
///   Sonnet 5.
///
/// Source: Anthropic "Thinking", "Effort" and "Models overview" docs, checked 2026-09-24. Older
/// models (Haiku 4.5, Sonnet 4.6, Opus 4.6 and before) keep the extended-thinking shape.
public enum AnthropicRequestPolicy {

    public struct Shape {
        public var thinking: [String: Any]?
        public var outputConfig: [String: Any]?
        public var temperature: Double?
        public var topP: Double?
    }

    /// Model families that reject manual `budget_tokens` thinking and non-default sampling.
    private static let adaptiveOnlyPrefixes = [
        "claude-fable-5", "claude-mythos-5", "claude-mythos-preview",
        "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
        "claude-sonnet-5",
    ]

    /// Only Sonnet 5 lets thinking be switched off; the others return a 400 for it.
    private static let canDisableThinking = ["claude-sonnet-5"]

    public static func isAdaptiveOnly(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        return adaptiveOnlyPrefixes.contains { id.hasPrefix($0) }
    }

    public static func shape(
        modelId: String,
        supportsReasoning: Bool,
        effort: ReasoningEffort,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> Shape {
        if isAdaptiveOnly(modelId) {
            var shape = Shape()   // sampling left at the model's defaults, thinking left on
            switch effort {
            case .off:
                if canDisableThinking.contains(where: { modelId.lowercased().hasPrefix($0) }) {
                    shape.thinking = ["type": "disabled"]
                } else {
                    // Can't be turned off; the closest thing is the least of it.
                    shape.outputConfig = ["effort": "low"]
                }
            case .low, .medium, .high:
                shape.outputConfig = ["effort": effort.rawValue]
                // Thinking is on without being asked, but its text is omitted by default, which
                // would leave the Thinking panel empty. Ask for the summary; the signature that
                // must go back with tool results is unaffected by this setting.
                shape.thinking = ["type": "adaptive", "display": "summarized"]
            }
            return shape
        }

        var shape = Shape()
        if supportsReasoning && effort != .off {
            // budget_tokens must be below max_tokens, or the request is rejected; a cap too small
            // to leave room for both thinking and an answer means skipping thinking, not failing.
            let wanted = effort == .high ? 4096 : (effort == .medium ? 2048 : 1024)
            let budget = min(wanted, maxTokens - 1024)
            if budget >= 1024 {
                shape.thinking = ["type": "enabled", "budget_tokens": budget]
                return shape
            }
        }
        shape.temperature = temperature
        // Outside the thinking case only: extended thinking rejects top_p, and requires
        // temperature 1.
        if topP > 0, topP < 1.0 { shape.topP = topP }
        return shape
    }
}
