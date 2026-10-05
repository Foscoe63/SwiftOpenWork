import Foundation

/// The system prompt in two parts: what holds still from turn to turn, and what changes.
///
/// A prompt cache only helps while the start of the request is byte-identical, and the system
/// prompt used to open with the git status and handoff note, which change after every edit. The
/// stable part now comes first; the rest follows `boundary`. Anthropic sends them as two system
/// blocks with the cache breakpoint between them; every other provider gets one plain string.
public enum PromptCache {
    public static let boundary = "\n\u{1}cache-boundary\u{1}\n"

    public static func join(stable: String, volatile: String) -> String {
        volatile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stable : stable + boundary + volatile
    }

    public static func split(_ prompt: String) -> (stable: String, volatile: String) {
        guard let range = prompt.range(of: boundary) else { return (prompt, "") }
        return (String(prompt[..<range.lowerBound]), String(prompt[range.upperBound...]))
    }

    public static func flattened(_ prompt: String) -> String {
        let parts = split(prompt)
        return parts.volatile.isEmpty ? parts.stable : parts.stable + "\n" + parts.volatile
    }
}
