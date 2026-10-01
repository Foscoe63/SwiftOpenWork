import Foundation

/// A file's before and after as aligned left/right rows grouped into hunks, so a reviewer can walk
/// the changes one at a time and take back any of them.
///
/// `InlineFileDiff` renders a bounded unified diff for a chat card. This one holds the whole file
/// and keeps what a review needs and a card does not: which rows belong to which hunk, and the
/// ability to produce the file with only chosen hunks undone.
public struct SideBySideDiff: Sendable, Equatable {

    public struct Row: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case context
            /// A line replaced by another: both sides present.
            case changed
            case removed
            case added
            /// `count` unchanged lines left out of the middle of the file.
            case gap(count: Int)
        }

        public var id: Int
        public var kind: Kind
        public var leftNumber: Int?
        public var leftText: String?
        public var rightNumber: Int?
        public var rightText: String?
        /// Index into `hunks`, for rows that belong to one.
        public var hunk: Int?
    }

    /// One contiguous run of changes: the lines removed from the old side and the lines that
    /// replaced them on the new side.
    public struct Hunk: Sendable, Equatable, Identifiable {
        public var id: Int
        /// 0-based position of the first line in the *new* file this hunk occupies (or, for a pure
        /// deletion, the line the removed text sat before).
        public var newStart: Int
        public var removedLines: [String]
        public var addedLines: [String]
        /// Id of the first row, for scrolling to the hunk.
        public var firstRowId: Int

        public var summary: String {
            switch (removedLines.isEmpty, addedLines.isEmpty) {
            case (true, _): return "+\(addedLines.count)"
            case (_, true): return "−\(removedLines.count)"
            default: return "+\(addedLines.count) −\(removedLines.count)"
            }
        }
    }

    public var rows: [Row]
    public var hunks: [Hunk]
    /// Whether the new text ended in a newline, so reverting can rebuild it the same way.
    var newEndsWithNewline: Bool
    var oldText: String
    var newLines: [String]

    public var isEmpty: Bool { hunks.isEmpty }

    /// Above this many cells the line-by-line LCS is not worth its memory; the middle (after
    /// trimming what both sides share) is treated as one replaced block instead.
    static let maxLCSCells = 4_000_000

    public static func make(old: String?, new: String?, contextLines: Int = 3) -> SideBySideDiff {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        // Trim the shared head and tail first. Most edits touch a small part of a large file, and
        // this keeps the quadratic table to the part that actually differs.
        var head = 0
        while head < oldLines.count, head < newLines.count, oldLines[head] == newLines[head] { head += 1 }
        var tail = 0
        while tail < oldLines.count - head, tail < newLines.count - head,
              oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] { tail += 1 }

        let oldMid = Array(oldLines[head..<(oldLines.count - tail)])
        let newMid = Array(newLines[head..<(newLines.count - tail)])
        let script: [Edit] = oldMid.count * newMid.count > maxLCSCells
            ? oldMid.map { Edit.removed($0) } + newMid.map { Edit.added($0) }
            : edits(old: oldMid, new: newMid)

        // Rebuild the whole script: shared head, the diffed middle, shared tail.
        var full: [Edit] = oldLines[..<head].map { Edit.context($0) }
        full += script
        full += oldLines[(oldLines.count - tail)...].map { Edit.context($0) }

        return build(script: full, oldText: old ?? "", newLines: newLines,
                     newEndsWithNewline: (new ?? "").hasSuffix("\n"), contextLines: contextLines)
    }

    // MARK: - Edit script

    enum Edit: Equatable {
        case context(String)
        case removed(String)
        case added(String)
    }

    /// Longest common subsequence walked into an edit script, so a moved block reads as a move
    /// rather than a rewrite.
    static func edits(old: [String], new: [String]) -> [Edit] {
        let n = old.count, m = new.count
        if n == 0 { return new.map { .added($0) } }
        if m == 0 { return old.map { .removed($0) } }
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Edit] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                out.append(.context(old[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(.removed(old[i])); i += 1
            } else {
                out.append(.added(new[j])); j += 1
            }
        }
        while i < n { out.append(.removed(old[i])); i += 1 }
        while j < m { out.append(.added(new[j])); j += 1 }
        return out
    }

    // MARK: - Building rows and hunks

    private static func build(
        script: [Edit], oldText: String, newLines: [String], newEndsWithNewline: Bool, contextLines: Int
    ) -> SideBySideDiff {
        // First pass: full aligned rows, with removed/added runs paired into `changed` rows.
        var rows: [Row] = []
        var hunks: [Hunk] = []
        var oldNumber = 0, newNumber = 0
        var index = 0
        func nextId() -> Int { rows.count }

        while index < script.count {
            if case .context(let text) = script[index] {
                oldNumber += 1; newNumber += 1
                rows.append(Row(id: nextId(), kind: .context, leftNumber: oldNumber, leftText: text,
                                rightNumber: newNumber, rightText: text, hunk: nil))
                index += 1
                continue
            }
            var removed: [String] = [], added: [String] = []
            while index < script.count {
                if case .removed(let t) = script[index] { removed.append(t) }
                else if case .added(let t) = script[index] { added.append(t) }
                else { break }
                index += 1
            }
            let hunkIndex = hunks.count
            let firstRow = nextId()
            let newStart = newNumber
            for k in 0..<max(removed.count, added.count) {
                let l = k < removed.count ? removed[k] : nil
                let r = k < added.count ? added[k] : nil
                if l != nil { oldNumber += 1 }
                if r != nil { newNumber += 1 }
                rows.append(Row(
                    id: nextId(),
                    kind: l != nil && r != nil ? .changed : (l != nil ? .removed : .added),
                    leftNumber: l != nil ? oldNumber : nil, leftText: l,
                    rightNumber: r != nil ? newNumber : nil, rightText: r,
                    hunk: hunkIndex
                ))
            }
            hunks.append(Hunk(id: hunkIndex, newStart: newStart, removedLines: removed, addedLines: added, firstRowId: firstRow))
        }

        // Second pass: collapse long unchanged stretches, keeping `contextLines` beside each hunk.
        var keep = [Bool](repeating: false, count: rows.count)
        for (position, row) in rows.enumerated() where row.hunk != nil {
            for offset in -contextLines...contextLines {
                let target = position + offset
                if rows.indices.contains(target) { keep[target] = true }
            }
        }
        var collapsed: [Row] = []
        var remap: [Int: Int] = [:]
        var skipped = 0
        for (position, row) in rows.enumerated() {
            if keep[position] {
                if skipped > 0 {
                    collapsed.append(Row(id: -1, kind: .gap(count: skipped), leftNumber: nil, leftText: nil,
                                         rightNumber: nil, rightText: nil, hunk: nil))
                    skipped = 0
                }
                remap[row.id] = collapsed.count
                collapsed.append(row)
            } else {
                skipped += 1
            }
        }
        if skipped > 0, !hunks.isEmpty {
            collapsed.append(Row(id: -1, kind: .gap(count: skipped), leftNumber: nil, leftText: nil,
                                 rightNumber: nil, rightText: nil, hunk: nil))
        }
        // Row ids must be unique and stable for ScrollViewReader; renumber after collapsing.
        for position in collapsed.indices { collapsed[position].id = position }
        for position in hunks.indices {
            hunks[position].firstRowId = remap[hunks[position].firstRowId] ?? 0
        }

        return SideBySideDiff(rows: hunks.isEmpty ? [] : collapsed, hunks: hunks,
                              newEndsWithNewline: newEndsWithNewline, oldText: oldText, newLines: newLines)
    }

    // MARK: - Reverting

    /// The new file with the hunks in `indices` put back to what the old file had there, and every
    /// other hunk left as the agent wrote it.
    public func reverting(_ indices: Set<Int>) -> String {
        if indices.count == hunks.count, !hunks.isEmpty { return oldText }
        var lines = newLines
        // Bottom to top, so an earlier hunk's position is not moved by a later one's revert.
        for hunk in hunks.reversed() where indices.contains(hunk.id) {
            let start = min(hunk.newStart, lines.count)
            let end = min(start + hunk.addedLines.count, lines.count)
            lines.replaceSubrange(start..<end, with: hunk.removedLines)
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (newEndsWithNewline ? "\n" : "")
    }

    static func splitLines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
