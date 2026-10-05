import Foundation
import SwiftOpenWorkCore

/// Radiant-style central tool result bound + time budget (tool-bounds.js parity).
public enum ToolBounds {
    public static let maxResultChars = 40_000

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
            notice: "Tool result truncated (\(truncated) chars omitted). Head and tail retained."
        )
    }
}
