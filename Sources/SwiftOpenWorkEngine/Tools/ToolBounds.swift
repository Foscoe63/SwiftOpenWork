import Foundation
import SwiftOpenWorkCore

/// Radiant-style central tool result bound + time budget (tool-bounds.js parity).
public enum ToolBounds {
    /// What one tool result may add to the transcript (about 6K tokens). Every later step re-sends
    /// it until it is folded away, so a 40K-character result (about 10K tokens) cost that again on
    /// each step. Head and tail are kept; the model can ask for the rest with offset/limit or a
    /// narrower search.
    public static let maxResultChars = 24_000

    public struct Bounded: Sendable {
        public let text: String
        public let truncatedChars: Int
        public let notice: String?
    }

    public static func boundResult(_ text: String, max: Int = maxResultChars) -> Bounded {
        let s = text
        guard s.count > max else {
            return Bounded(text: s, truncatedChars: 0, notice: nil)
        }
        let head = Int(Double(max) * 0.7)
        let tail = max - head
        let sliced = String(s.prefix(head)) + "\n\n…\n\n" + String(s.suffix(tail))
        let truncated = s.count - max
        return Bounded(
            text: sliced,
            truncatedChars: truncated,
            notice: "Tool result truncated (\(truncated) chars omitted). Head and tail retained; ask for a narrower range or search to see the rest."
        )
    }
}
