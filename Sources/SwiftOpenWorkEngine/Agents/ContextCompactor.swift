import Foundation
import SwiftOpenWorkCore

/// Keep a long session inside its context budget without erasing what the work established.
///
/// Dropping the middle of a conversation is cheap; dropping the *record* of it is not. A coding
/// session that forgets which files it already edited re-edits them, re-runs builds it already
/// ran, and contradicts itself. So compaction keeps a factual digest — files touched, commands
/// run and their verdicts — assembled from the tool calls themselves rather than from a model
/// summary, which makes it deterministic, free, and testable.
public enum ContextCompactor {

    // MARK: - Tool-result folding

    /// Fold oversized tool observations into short stubs, keeping the last `keepLast` intact.
    ///
    /// Recent results are what the next step reasons about; older ones have usually already been
    /// acted on and only their existence still matters.
    ///
    /// Folding rewrites history, and the local engine's cache can only continue a transcript that
    /// extends what it has seen — so every fold costs a full re-prefill. Folding one result per
    /// step, as a sliding window did, paid that on every step once four results existed: a real
    /// run logged "Context cache reset: history diverged" fifteen times in one turn. Folds now
    /// wait until `batch` results are due and then take them all, so the cache survives the
    /// steps in between.
    public static func foldOldToolResults(_ messages: [ChatMessage], keepLast: Int = 4, batch: Int = 4) -> [ChatMessage] {
        var toolIndices: [Int] = []
        for (i, m) in messages.enumerated() where m.role == .tool {
            toolIndices.append(i)
        }
        guard toolIndices.count > keepLast else { return messages }

        let foldSet = Set(toolIndices.dropLast(keepLast).filter { messages[$0].content.count > 500 })
        guard foldSet.count >= max(1, batch) else { return messages }
        return messages.enumerated().map { i, m in
            guard foldSet.contains(i) else { return m }
            var copy = m
            let preview = String(m.content.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            copy.content = "[Earlier tool result compacted] \(preview)…"
            return copy
        }
    }

    // MARK: - Digest

    /// What a stretch of conversation actually did, in facts rather than prose.
    public struct Digest: Sendable, Equatable {
        public var filesWritten: [String] = []
        public var filesEdited: [String] = []
        public var filesDeleted: [String] = []
        public var commands: [String] = []
        public var failures: [String] = []

        public var isEmpty: Bool {
            filesWritten.isEmpty && filesEdited.isEmpty && filesDeleted.isEmpty
                && commands.isEmpty && failures.isEmpty
        }

        public func rendered() -> String {
            guard !isEmpty else { return "" }
            var lines: [String] = []
            if !filesEdited.isEmpty { lines.append("edited: \(filesEdited.joined(separator: ", "))") }
            if !filesWritten.isEmpty { lines.append("wrote: \(filesWritten.joined(separator: ", "))") }
            if !filesDeleted.isEmpty { lines.append("deleted: \(filesDeleted.joined(separator: ", "))") }
            if !commands.isEmpty { lines.append("ran: \(commands.joined(separator: "; "))") }
            if !failures.isEmpty { lines.append("failed: \(failures.joined(separator: "; "))") }
            return lines.joined(separator: "\n")
        }
    }

    /// Tool names whose argument carries a path worth remembering.
    private static let writeTools: Set<String> = ["file_write", "write_file", "create_file", "save_file"]
    private static let editTools: Set<String> = ["edit_file", "file_edit", "multi_edit", "edit_file_multi"]
    private static let deleteTools: Set<String> = ["file_delete", "delete_file", "rm"]
    private static let commandTools: Set<String> = [
        "terminal_command", "run_command", "build_project", "run_tests",
    ]

    /// Build a digest from the tool calls carried by `messages`.
    public static func digest(of messages: [ChatMessage], limitPerCategory: Int = 12) -> Digest {
        var digest = Digest()
        var seenFiles = Set<String>()

        for message in messages {
            for call in message.toolCalls {
                let name = ToolCallRepair.canonicalName(call.toolName)
                let args = ToolCallRepair.normalizeArguments(tool: name, arguments(call.argumentsJson))

                if writeTools.contains(name) || editTools.contains(name) || deleteTools.contains(name) {
                    guard let path = (args["path"] ?? args["filename"] ?? args["filepath"] ?? args["file"]) as? String,
                          !path.isEmpty,
                          seenFiles.insert("\(name):\(path)").inserted else { continue }
                    let short = (path as NSString).lastPathComponent
                    if writeTools.contains(name) { digest.filesWritten.append(short) }
                    else if editTools.contains(name) { digest.filesEdited.append(short) }
                    else { digest.filesDeleted.append(short) }
                } else if commandTools.contains(name) {
                    let command = (args["command"] as? String) ?? name
                    let verdict = call.status == .error || call.status == .failed ? " (failed)" : ""
                    let entry = "\(String(command.prefix(80)))\(verdict)"
                    if !digest.commands.contains(entry) { digest.commands.append(entry) }
                }

                // Any failed call is worth remembering so it is not blindly retried.
                if call.status == .error || call.status == .failed,
                   let reason = call.errorMessage, !reason.isEmpty {
                    let entry = "\(call.toolName): \(String(reason.prefix(100)))"
                    if !digest.failures.contains(entry) { digest.failures.append(entry) }
                }
            }
        }

        digest.filesWritten = Array(digest.filesWritten.prefix(limitPerCategory))
        digest.filesEdited = Array(digest.filesEdited.prefix(limitPerCategory))
        digest.filesDeleted = Array(digest.filesDeleted.prefix(limitPerCategory))
        digest.commands = Array(digest.commands.prefix(limitPerCategory))
        digest.failures = Array(digest.failures.prefix(limitPerCategory / 2))
        return digest
    }

    private static func arguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    // MARK: - Milestones

    /// A tool result that marks settled progress: everything before it can be summarised without
    /// losing anything the next step needs.
    ///
    /// Token-count compaction fires whenever the budget says so, which can be mid-task — right
    /// after reading three files and before using them. A milestone is the opposite: a green test
    /// run or a clean tree means the work behind it is *finished*, so that is the cheapest possible
    /// moment to trade detail for room.
    public static func isMilestone(toolName: String, succeeded: Bool, output: String) -> Bool {
        guard succeeded else { return false }
        let name = toolName.lowercased()
        let text = output.lowercased()

        if name == "run_tests" || name == "build_project" {
            // `succeeded` already reflects the exit code; the summary states it too.
            return text.contains("succeeded") && !text.contains("error")
        }
        if name == "git_status" {
            return text.contains("working tree clean")
        }
        return false
    }

    /// Compact at a milestone even when the token budget has not been reached.
    ///
    /// Uses a lower bar than the budget path — there is no point summarising four messages — but
    /// does not wait for pressure, because waiting means compacting at a worse moment later.
    public static func compactAtMilestone(
        _ messages: [ChatMessage],
        minimumMessages: Int = 12,
        keepRecent: Int = 6
    ) -> (messages: [ChatMessage], didCompact: Bool) {
        guard messages.count >= minimumMessages else { return (messages, false) }
        // Threshold 0 forces the existing path to act; it already keeps the task and a digest.
        return compactIfNeeded(messages, thresholdTokens: 0, keepRecent: keepRecent)
    }

    // MARK: - Compaction

    /// Drop the middle of the conversation when it exceeds the budget, keeping the original task,
    /// a digest of what the dropped stretch did, and the most recent turns.
    public static func compactIfNeeded(
        _ messages: [ChatMessage],
        thresholdTokens: Int,
        keepRecent: Int = 12
    ) -> (messages: [ChatMessage], didCompact: Bool) {
        let estimate = estimateTokens(messages)
        guard estimate > thresholdTokens, messages.count > keepRecent + 2 else {
            return (messages, false)
        }

        // The first user message is the task. Losing it is how an agent ends up confidently
        // finishing something nobody asked for.
        let head: [ChatMessage]
        if let firstUser = messages.firstIndex(where: { $0.role == .user }) {
            head = Array(messages[0...firstUser])
        } else {
            head = Array(messages.prefix(1))
        }

        let tailStart = max(head.count, messages.count - keepRecent)
        let dropped = Array(messages[head.count..<tailStart])
        let tail = Array(messages[tailStart...])
        guard !dropped.isEmpty else { return (messages, false) }

        let facts = digest(of: dropped)
        var body = "[Context compacted] \(dropped.count) earlier message(s) were dropped to free context."
        if !facts.isEmpty {
            body += " What they established:\n\(facts.rendered())"
            body += "\nDo not redo this work. Re-read a file if you need its current contents."
        }

        let note = ChatMessage(
            sessionId: messages.first?.sessionId ?? "",
            role: .user,
            content: body
        )
        return (head + [note] + tail, true)
    }

    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        let chars = messages.reduce(0) { $0 + $1.content.count + ($1.reasoning?.count ?? 0) }
        return max(1, chars / 4)
    }
}
