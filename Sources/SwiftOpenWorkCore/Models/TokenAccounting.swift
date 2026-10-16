import Foundation

/// The figures behind the composer's Prompt / Sent / Recv bar.
public struct ChatTokenStats: Equatable, Sendable {
    /// The last model call's prompt, as the provider billed it.
    public var lastPromptTokens: Int
    /// Prompt tokens billed across the whole session.
    public var sentTokens: Int
    /// Completion tokens billed across the whole session.
    public var receivedTokens: Int

    public init(lastPromptTokens: Int = 0, sentTokens: Int = 0, receivedTokens: Int = 0) {
        self.lastPromptTokens = lastPromptTokens
        self.sentTokens = sentTokens
        self.receivedTokens = receivedTokens
    }
}

public enum TokenAccounting: Sendable {
    /// Rough estimate: about four UTF-8 bytes per token.
    public static func estimate(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, (trimmed.utf8.count + 3) / 4)
    }

    /// The box while something is typed in it; otherwise the last billed prompt.
    public static func displayedPrompt(draft: String, lastBilledPrompt: Int) -> Int {
        let live = estimate(draft)
        return live > 0 ? live : max(0, lastBilledPrompt)
    }

    public static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// Sums what the provider reported. A message saved before per-turn totals existed falls back
    /// to its single recorded figure, which undercounts a turn with tool steps but is never wrong
    /// in the other direction.
    public static func stats(for messages: [ChatMessage]) -> ChatTokenStats {
        var stats = ChatTokenStats()
        for message in messages {
            stats.sentTokens += max(0, max(message.billedPromptTokens, message.promptTokens))
            stats.receivedTokens += max(0, max(message.billedCompletionTokens, message.completionTokens))
            if message.promptTokens > 0 { stats.lastPromptTokens = message.promptTokens }
        }
        return stats
    }
}
