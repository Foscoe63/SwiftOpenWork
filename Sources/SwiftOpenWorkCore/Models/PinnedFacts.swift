import Foundation

/// The rules for a session's pinned facts (`/pin`, `/unpin`, `/pins`).
///
/// Kept apart from the command handler so the limits are tested without a chat to type into. A
/// pinned fact rides in every compaction note, so each one costs tokens for the rest of the
/// session: that is why there is a cap, and why it is short.
public enum PinnedFacts {
    public static let maxFacts = 20
    public static let maxLength = 500

    public enum AddResult: Equatable, Sendable {
        case added(count: Int)
        case duplicate
        case empty
        case full
    }

    public enum RemoveResult: Equatable, Sendable {
        case removed(String)
        case cleared(Int)
        case notFound
    }

    public static func add(_ raw: String, to facts: inout [String]) -> AddResult {
        let flat = raw.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return .empty }
        let fact = flat.count > maxLength ? String(flat.prefix(maxLength - 1)) + "…" : flat
        if facts.contains(where: { $0.caseInsensitiveCompare(fact) == .orderedSame }) { return .duplicate }
        guard facts.count < maxFacts else { return .full }
        facts.append(fact)
        return .added(count: facts.count)
    }

    /// `argument` is a 1-based number as `listing` prints it, or `all`.
    public static func remove(_ argument: String, from facts: inout [String]) -> RemoveResult {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "all" {
            let count = facts.count
            facts.removeAll()
            return count == 0 ? .notFound : .cleared(count)
        }
        guard let number = Int(trimmed), facts.indices.contains(number - 1) else { return .notFound }
        return .removed(facts.remove(at: number - 1))
    }

    public static func listing(_ facts: [String]) -> String {
        guard !facts.isEmpty else {
            return "No pinned facts. `/pin <fact>` keeps a fact in the model's context through compaction."
        }
        return "Pinned facts (kept through compaction):\n"
            + facts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}
