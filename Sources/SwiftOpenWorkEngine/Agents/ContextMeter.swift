import Foundation
import SwiftOpenWorkCore

/// How full the model's context window is, before you find out the hard way.
///
/// Running out of context does not look like an error. It looks like the agent quietly forgetting
/// the file you discussed twenty messages ago, or compaction throwing away the part you cared
/// about. Both are indistinguishable from the model being stupid, which is why people blame the
/// model. A number next to the composer turns that into a decision: keep going, or start a new
/// chat while the thread is still coherent.
public struct ContextMeter: Equatable, Sendable {

    public enum Pressure: Sendable {
        case comfortable
        case filling
        case tight
    }

    /// Prompt tokens the provider charged for the most recent turn.
    public var used: Int
    /// The selected model's window.
    public var limit: Int

    /// True when `used` is our own estimate of the transcript, not the provider's number.
    public var isEstimate: Bool

    public init(used: Int, limit: Int, isEstimate: Bool = false) {
        self.used = used
        self.limit = limit
        self.isEstimate = isEstimate
    }

    public var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1, Double(used) / Double(limit))
    }

    public var pressure: Pressure {
        switch fraction {
        case ..<0.6: return .comfortable
        case ..<0.85: return .filling
        default: return .tight
        }
    }

    /// Shown whenever there is a figure. It used to hide below 50%, which made it vanish for
    /// anyone whose real usage is a fraction of a large window — and a gauge that appears only
    /// when it is already late is not much of a gauge.
    public var isWorthShowing: Bool {
        limit > 0 && used > 0
    }

    public var label: String {
        "\(isEstimate ? "~" : "")\(Self.abbreviate(used)) / \(Self.abbreviate(limit))"
    }

    public var help: String {
        let percent = Int((fraction * 100).rounded())
        if isEstimate {
            return "About \(percent)% of this model's context window is in use (estimated from the transcript; the provider's own count was not usable)."
        }
        switch pressure {
        case .comfortable, .filling:
            return "\(percent)% of this model's context window is in use."
        case .tight:
            return "\(percent)% of this model's context window is in use. "
                + "Older messages will start being summarized away — consider starting a new chat."
        }
    }

    public static func abbreviate(_ tokens: Int) -> String {
        guard tokens >= 1000 else { return "\(tokens)" }
        let thousands = Double(tokens) / 1000
        return thousands >= 100
            ? "\(Int(thousands.rounded()))k"
            : String(format: "%.1fk", thousands).replacingOccurrences(of: ".0k", with: "k")
    }

    /// Read the last turn's prompt size out of a transcript.
    ///
    /// Estimating from character counts was the alternative and it lies in both directions: it
    /// ignores the system prompt, the tool schemas, and every tool result the model saw. The
    /// provider's own number is the only honest one, so a session that has not had a reply yet
    /// simply shows nothing rather than a guess.
    public static func forSession(_ messages: [ChatMessage], contextWindow: Int) -> ContextMeter? {
        guard contextWindow > 0 else { return nil }
        guard let used = messages.last(where: { $0.promptTokens > 0 })?.promptTokens else {
            return nil
        }
        return ContextMeter(used: used, limit: contextWindow)
    }

    /// Fixed allowance for the system prompt and tool schemas, which the transcript lacks.
    public static let overheadTokens = 12_000

    /// Our estimate of what the next request carries: the model-facing transcript, three
    /// characters a token, plus `overheadTokens`.
    public static func estimatedUsage(of history: [ChatMessage]) -> Int {
        var characters = 0
        let hasToolMessages = history.contains { $0.role == .tool }
        for message in history {
            characters += message.content.count
            for call in message.toolCalls {
                characters += call.argumentsJson.count
                if !hasToolMessages { characters += call.resultOutput?.count ?? 0 }
            }
        }
        return characters / 3 + overheadTokens
    }

    /// The meter for a session.
    ///
    /// The provider's count is preferred, but a local server can report a figure that is not one
    /// request's size — 440k against a 262k window, from a chat holding about 55k — and a number
    /// the model could never have received is worse than none. When the report is over the window,
    /// or far above what the transcript can account for (the chat was compacted since), the
    /// estimate is shown instead, marked with `~`.
    public static func forSession(_ session: Session, contextWindow: Int) -> ContextMeter? {
        guard contextWindow > 0 else { return nil }
        let estimate = estimatedUsage(of: session.modelHistory())
        guard let reported = session.messages.last(where: { $0.promptTokens > 0 })?.promptTokens else {
            return nil
        }
        if reported > contextWindow || reported > estimate * 2 {
            return ContextMeter(used: estimate, limit: contextWindow, isEstimate: true)
        }
        return ContextMeter(used: reported, limit: contextWindow)
    }
}
