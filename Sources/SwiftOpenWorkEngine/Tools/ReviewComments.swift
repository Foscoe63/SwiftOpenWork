import Foundation

/// A note left on a line of the agent's change while reviewing it, to be sent back as a batch.
///
/// Reviewing a diff produces opinions about particular lines; typing each into the chat with the
/// file and line spelled out is what makes people skip it. Comments collect while you read and go
/// to the agent together, each carrying the place it is about.
public struct ReviewComment: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Workspace-relative where possible.
    public var path: String
    /// 1-based line in the file as it is now.
    public var line: Int
    /// The line itself, so the comment still makes sense if the file has moved on.
    public var excerpt: String
    public var text: String

    public init(id: UUID = UUID(), path: String, line: Int, excerpt: String, text: String) {
        self.id = id
        self.path = path
        self.line = line
        self.excerpt = excerpt
        self.text = text
    }

    /// The message that hands a batch to the agent, grouped by file in line order.
    public static func prompt(for comments: [ReviewComment]) -> String {
        let cleaned = comments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cleaned.isEmpty else { return "" }
        var lines = [
            "I reviewed your changes and left \(cleaned.count) comment\(cleaned.count == 1 ? "" : "s"). Address each one in the code — read the file first, since it may have changed — and say briefly what you did for each. If you disagree with a comment, say why instead of changing the code.",
            "",
        ]
        let byFile = Dictionary(grouping: cleaned, by: \.path)
        for path in byFile.keys.sorted() {
            lines.append("### \(path)")
            for comment in (byFile[path] ?? []).sorted(by: { $0.line < $1.line }) {
                let excerpt = comment.excerpt.trimmingCharacters(in: .whitespaces)
                lines.append("- line \(comment.line)" + (excerpt.isEmpty ? "" : " (`\(String(excerpt.prefix(120)))`)") + ": " + comment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
