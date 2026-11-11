import Foundation
import SwiftOpenWorkCore

/// What the agent remembers, put in front of it at the start of every turn.
///
/// `memory_store` and `memory_recall` already existed, but nothing loaded a memory unless the
/// model thought to ask for it, and a model that starts from nothing does not know there is
/// anything to ask about. This block is that missing half: the facts saved for this workspace and
/// the project's own `.swiftopenwork/memory.md` are read into the system prompt each turn.
public enum MemoryPrompt {
    /// A file in the repository, written by `memory_store` with `scope: "project"` or by hand.
    /// It travels with the repository, so a teammate's agent starts with the same notes.
    public static let projectFileRelativePath = ".swiftopenwork/memory.md"

    public static let maxItems = 20
    public static let maxCharacters = 3_000
    public static let maxProjectFileCharacters = 4_000
    public static let maxRecalledCharacters = 2_500
    /// Recall must never hold a turn up: the model starts without it after this long.
    public static let recallTimeoutSeconds = 4.0

    /// The request to recall against. A bare "Continue" carries no topic, so it uses the last real request.
    public static func recallQuery(prompt: String, previousUserMessages: [String]) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if AutoContinuePolicy.isContinuePrompt(text) {
            text = previousUserMessages.last { !AutoContinuePolicy.isContinuePrompt($0) && $0.count > 40 }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return text.isEmpty ? nil : String(text.prefix(600))
    }

    /// What a recall returned, ready for the prompt; nil when it failed or found nothing.
    public static func usableRecall(_ output: String) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("Error"), !text.lowercased().contains("no memories found"),
              text != "[]", text != "{}" else { return nil }
        return String(text.prefix(maxRecalledCharacters))
    }

    /// Facts for this workspace, newest first, plus the ones saved before memories were scoped.
    public static func relevant(_ all: [MemoryItem], workspaceId: String) -> [MemoryItem] {
        all.filter { $0.workspaceId == workspaceId || $0.workspaceId == "default-workspace" }
            .filter { $0.category != .sessionSummary }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func projectFile(workspaceRoot: String) -> String? {
        guard !workspaceRoot.isEmpty else { return nil }
        let path = (workspaceRoot as NSString).appendingPathComponent(projectFileRelativePath)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxProjectFileCharacters))
    }

    /// Empty when there is nothing to remember, so callers can interpolate it unconditionally.
    public static func promptBlock(items: [MemoryItem], projectFile: String?, recalled: String? = nil) -> String {
        var sections: [String] = []
        if let recalled, !recalled.isEmpty {
            sections.append("Recalled from long-term memory for this request:\n\(recalled)")
        }
        if let projectFile, !projectFile.isEmpty {
            sections.append("From `\(projectFileRelativePath)` (this project's notes):\n\(projectFile)")
        }
        var used = 0
        var lines: [String] = []
        for item in items.prefix(maxItems) {
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            let line = "- [\(item.key)] \(content)"
            guard used + line.count <= maxCharacters else { break }
            used += line.count
            lines.append(line)
        }
        if !lines.isEmpty { sections.append("Saved facts:\n" + lines.joined(separator: "\n")) }
        guard !sections.isEmpty else { return "" }
        return """
        ### What you remember
        These were saved in earlier sessions. Treat them as true unless the code in front of you says otherwise, and do not re-derive them.
        \(sections.joined(separator: "\n\n"))
        Save a durable fact with `memory_store` (key + content): a decision and why, a convention, a correction the user gave you, how to build or test. \
        Use `scope: "project"` for what any contributor's agent should know. Do not save task progress or anything you can read from the code.
        """
    }

    /// Replace the fact saved under the same key rather than stacking duplicates.
    public static func upserting(_ item: MemoryItem, into all: [MemoryItem]) -> [MemoryItem] {
        var result = all
        if let index = result.firstIndex(where: { $0.workspaceId == item.workspaceId && $0.key.lowercased() == item.key.lowercased() }) {
            var updated = item
            updated.id = result[index].id
            updated.createdAt = result[index].createdAt
            result[index] = updated
        } else {
            result.insert(item, at: 0)
        }
        return result
    }

    /// Append a note to the project's memory file, creating it (and `.swiftopenwork/`) if needed.
    @discardableResult
    public static func appendToProjectFile(key: String, content: String, workspaceRoot: String) -> Bool {
        guard !workspaceRoot.isEmpty else { return false }
        let path = (workspaceRoot as NSString).appendingPathComponent(projectFileRelativePath)
        let line = "- **\(key)**: \(content.replacingOccurrences(of: "\n", with: " "))\n"
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "# Project memory\n\n"
            // Same key: replace its line.
            let marker = "- **\(key)**:"
            var lines = existing.components(separatedBy: "\n")
            if let index = lines.firstIndex(where: { $0.hasPrefix(marker) }) {
                lines[index] = line.trimmingCharacters(in: .newlines)
                try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                try (existing.hasSuffix("\n") ? existing : existing + "\n").appending(line)
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }
}
