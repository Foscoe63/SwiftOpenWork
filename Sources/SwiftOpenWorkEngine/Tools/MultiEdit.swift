import Foundation

/// Apply several edits to one file's contents, all or nothing.
///
/// A local model asked to make four related changes to a file spends four round trips doing it —
/// and each round trip re-reads, re-reasons and can drift. Worse, if the third fails the file is
/// left in a state matching neither the before nor the intended after, and the model must work out
/// which of its edits landed. Half-applied is the worst outcome available, so this computes the
/// whole result first and only then hands back a string to write.
public enum MultiEdit {

    public struct Edit: Sendable, Equatable {
        public var oldString: String
        public var newString: String
        public var replaceAll: Bool

        public init(oldString: String, newString: String, replaceAll: Bool = false) {
            self.oldString = oldString
            self.newString = newString
            self.replaceAll = replaceAll
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case noEdits
        case emptyOldString(index: Int)
        case notFound(index: Int, oldString: String, hint: String)
        case ambiguous(index: Int, count: Int)

        /// Phrased for the model that has to fix it: what failed, which edit, and what to do.
        public var message: String {
            switch self {
            case .noEdits:
                return "multi_edit requires at least one edit."
            case .emptyOldString(let index):
                return "multi_edit: edit \(index + 1) has an empty old_string."
            case .notFound(let index, let oldString, let hint):
                let preview = String(oldString.prefix(60)).replacingOccurrences(of: "\n", with: "⏎")
                return "multi_edit: edit \(index + 1) did not match. Nothing was written — the file is unchanged. Looked for: \(preview)\(hint)"
            case .ambiguous(let index, let count):
                return "multi_edit: edit \(index + 1) matched \(count) times. Nothing was written — the file is unchanged. Add surrounding context, or set replace_all for that edit."
            }
        }
    }

    public struct Applied: Sendable, Equatable {
        public var contents: String
        /// Replacements made, per edit, in order.
        public var replacements: [Int]

        public var total: Int { replacements.reduce(0, +) }
    }

    /// Apply `edits` in order to `contents`.
    ///
    /// Order matters: each edit sees the result of the ones before it, which is what lets an edit
    /// target text an earlier edit introduced. The flip side — an edit unexpectedly matching text
    /// an earlier one inserted — is why the ambiguity check is per-edit and evaluated against the
    /// contents as they stand at that point, not against the original.
    public static func apply(_ edits: [Edit], to contents: String) -> Result<Applied, Failure> {
        guard !edits.isEmpty else { return .failure(.noEdits) }

        var working = contents
        var replacements: [Int] = []

        for (index, edit) in edits.enumerated() {
            guard !edit.oldString.isEmpty else {
                return .failure(.emptyOldString(index: index))
            }
            let count = working.components(separatedBy: edit.oldString).count - 1
            if count == 0 {
                if let m = EditMatcher.fuzzyMatch(old: edit.oldString, new: edit.newString, in: working) {
                    working = working.replacingCharacters(in: m.range, with: m.replacement)
                    replacements.append(1)
                    continue
                }
                return .failure(.notFound(index: index, oldString: edit.oldString, hint: EditMatcher.missHint(old: edit.oldString, in: working)))
            }
            if count > 1 && !edit.replaceAll {
                return .failure(.ambiguous(index: index, count: count))
            }
            if edit.replaceAll {
                working = working.replacingOccurrences(of: edit.oldString, with: edit.newString)
                replacements.append(count)
            } else if let range = working.range(of: edit.oldString) {
                working = working.replacingCharacters(in: range, with: edit.newString)
                replacements.append(1)
            }
        }

        return .success(Applied(contents: working, replacements: replacements))
    }

    /// Read edits out of a tool call's already-parsed arguments.
    ///
    /// Local models are inconsistent about casing and about whether a single edit arrives wrapped
    /// in a list, so both spellings and both shapes are accepted. Anything else is rejected rather
    /// than guessed at — a misread edit list writes the wrong thing to disk.
    public static func parseEdits(from dict: [String: Any]) -> [Edit]? {
        let raw = dict["edits"] ?? dict["changes"] ?? dict["replacements"]

        let list: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            list = array
        } else if let single = raw as? [String: Any] {
            list = [single]
        } else if let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) {
            if let array = decoded as? [[String: Any]] {
                list = array
            } else if let single = decoded as? [String: Any] {
                list = [single]
            } else {
                return nil
            }
        } else {
            return nil
        }

        var edits: [Edit] = []
        for entry in list {
            guard let old = (entry["old_string"] ?? entry["oldString"] ?? entry["old"]) as? String,
                  let new = (entry["new_string"] ?? entry["newString"] ?? entry["new"]) as? String else {
                return nil
            }
            let all = (entry["replace_all"] ?? entry["replaceAll"]) as? Bool ?? false
            edits.append(Edit(oldString: old, newString: new, replaceAll: all))
        }
        return edits.isEmpty ? nil : edits
    }
}

/// Forgiving match for `old_string` when the exact text isn't in the file.
///
/// Models reconstruct code from memory or a truncated read, so the usual miss is not wrong content
/// but wrong whitespace: a stray leading/trailing newline, different indentation, CRLF vs LF.
/// Compares line by line with surrounding whitespace ignored; only a unique match is accepted.
public enum EditMatcher {

    public struct Match {
        public var range: Range<String.Index>
        /// `new` with its indentation and edge newlines adapted to the matched region.
        public var replacement: String
    }

    private static func indent(of line: Substring) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    public static func fuzzyMatch(old: String, new: String, in contents: String) -> Match? {
        var oldLines = old.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        while let f = oldLines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { oldLines.removeFirst() }
        while let l = oldLines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { oldLines.removeLast() }
        guard !oldLines.isEmpty else { return nil }
        let wanted = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }

        // Content lines with their ranges (excluding line terminators).
        var lines: [(text: Substring, range: Range<String.Index>)] = []
        var start = contents.startIndex
        while start < contents.endIndex {
            let nl = contents[start...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) ?? contents.endIndex
            lines.append((contents[start..<nl], start..<nl))
            start = nl < contents.endIndex ? contents.index(after: nl) : nl
        }
        guard lines.count >= wanted.count else { return nil }

        var hits: [Int] = []
        for i in 0...(lines.count - wanted.count) {
            var ok = true
            for j in 0..<wanted.count where lines[i + j].text.trimmingCharacters(in: .whitespaces) != wanted[j] {
                ok = false
                break
            }
            if ok { hits.append(i) }
            if hits.count > 1 { return nil }
        }
        guard let first = hits.first else { return nil }
        let range = lines[first].range.lowerBound..<lines[first + wanted.count - 1].range.upperBound

        var newLines = new.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let f = newLines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { newLines.removeFirst() }
        while let l = newLines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { newLines.removeLast() }

        let fileIndent = indent(of: lines[first].text)
        let modelIndent = indent(of: oldLines[0])
        if fileIndent != modelIndent {
            newLines = newLines.map { line in
                if line.isEmpty { return line }
                let body = line.hasPrefix(modelIndent) ? String(line.dropFirst(modelIndent.count)) : line
                return fileIndent + body
            }
        }
        return Match(range: range, replacement: newLines.joined(separator: "\n"))
    }

    /// Why an edit missed, phrased so the model can correct itself instead of retrying blind.
    public static func missHint(old: String, in contents: String) -> String {
        let firstLine = old.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return "" }
        let fileLines = contents.components(separatedBy: .newlines)
        if let idx = fileLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == firstLine }) {
            let end = min(fileLines.count, idx + 4)
            let snippet = fileLines[idx..<end].joined(separator: "\n")
            return " The first line of old_string exists at line \(idx + 1), but the following lines differ. Actual text there:\n\(snippet)\nRe-read the file and copy old_string exactly."
        }
        return " The first line of old_string does not appear anywhere in the file — it may have changed since you last read it. Re-read the file before editing."
    }
}
