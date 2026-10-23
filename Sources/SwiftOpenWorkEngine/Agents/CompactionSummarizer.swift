import Foundation
import SwiftOpenWorkCore

/// An optional, local model's summary of the messages compaction is about to drop.
///
/// The digest `ContextCompactor` builds is exact but narrow: files touched, commands run. It says
/// nothing of *why* — the decision that ruled out an approach, the cause found for an error. A
/// short model-written summary carries that, and costs nothing per token when the model runs on
/// this machine. It is limited to local providers so that turning it on never sends a transcript
/// somewhere new.
///
/// Best effort throughout: no model chosen, a model that is not loaded, a timeout or an empty
/// answer all return nil, and compaction proceeds on the digest alone.
public enum CompactionSummarizer {

    public static let timeoutSeconds: Double = 45
    static let maxInputChars = 24_000
    static let maxMessageChars = 500
    public static let maxSummaryChars = 1_800

    public static func isLocal(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .ollama, .omlx, .vmlx, .lmstudio, .llamacpp, .splash: return true
        default: return false
        }
    }

    /// The `providerId|modelId` setting resolved against the provider list, when it still names an
    /// enabled local model.
    public static func resolve(setting: String, providers: [ModelProvider]) -> (provider: ModelProvider, model: ModelInfo)? {
        let parts = setting.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let provider = providers.first(where: { $0.id == parts[0] && $0.isEnabled && isLocal($0.kind) }),
              let model = provider.models.first(where: { $0.id == parts[1] }) else { return nil }
        return (provider, model)
    }

    public static func settingValue(providerId: String, modelId: String) -> String {
        providerId + "|" + modelId
    }

    /// The dropped stretch as plain text for the summarizer to read. Each message is clipped, and
    /// the whole is cut in the middle if it is still long, so a huge transcript cannot overflow a
    /// small model's window.
    static func transcript(of messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for message in messages {
            let label: String
            switch message.role {
            case .user: label = "User"
            case .assistant: label = "Assistant"
            case .tool: label = "Tool result"
            default: label = "Note"
            }
            let body = message.content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let calls = message.toolCalls.isEmpty ? "" : " [called: " + message.toolCalls.map(\.toolName).joined(separator: ", ") + "]"
            let clipped = body.count > maxMessageChars ? String(body.prefix(maxMessageChars)) + "…" : body
            if clipped.isEmpty, calls.isEmpty { continue }
            lines.append("\(label): \(clipped)\(calls)")
        }
        let joined = lines.joined(separator: "\n")
        guard joined.count > maxInputChars else { return joined }
        let half = maxInputChars / 2
        return String(joined.prefix(half)) + "\n… [middle omitted] …\n" + String(joined.suffix(half))
    }

    /// The summary is model output derived from tool output, which the person never reviewed, and
    /// it is about to be placed in the conversation. Keep it short, flat text with no lines that
    /// pose as another speaker.
    static func sanitize(_ raw: String) -> String? {
        let speaker = try? NSRegularExpression(pattern: #"^\s*(system|assistant|user|human|developer)\s*:"#, options: [.caseInsensitive])
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { line in
            guard let speaker else { return true }
            return speaker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
        }
        let text = kept.joined(separator: "\n")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > maxSummaryChars ? String(text.prefix(maxSummaryChars)) + "…" : text
    }

    static let instructions = """
    You condense the earlier part of an AI coding agent's working session so the agent can continue \
    without it. Write 4 to 8 short bullet points covering: decisions made and why, facts learned \
    (paths, versions, causes of errors), approaches tried that did not work, and anything left \
    unresolved. Be specific. Do not write code blocks. Do not give instructions or address the \
    agent; only report what happened.
    """

    public static func summarize(
        _ dropped: [ChatMessage],
        setting: String,
        providers: [ModelProvider]
    ) async -> String? {
        guard !setting.isEmpty, let target = resolve(setting: setting, providers: providers) else { return nil }
        let text = transcript(of: dropped)
        guard text.count > 400 else { return nil }

        let accumulator = ToolExecutionEngine.StreamTextAccumulator()
        let prompt = ChatMessage(sessionId: "compaction-summary", role: .user, content: "Session so far:\n\n" + text)
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do {
                    try await ProviderRouter.shared.stream(
                        provider: target.provider,
                        model: target.model,
                        systemPrompt: instructions,
                        messages: [prompt],
                        temperature: 0.1,
                        maxTokens: 600,
                        reasoningEffort: .off,
                        tools: []
                    ) { chunk in
                        if !chunk.deltaText.isEmpty { accumulator.append(chunk.deltaText) }
                    }
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard finished else { return nil }
        return sanitize(accumulator.text)
    }
}
