import Foundation
import SwiftOpenWorkCore

/// Every file this session touched, assembled from the session's own tool calls.
///
/// Per-turn review already exists and reads the checkpoint store, which holds real before/after
/// contents — but only for the current turn, deliberately: `beginTurn` discards the previous
/// window, because an agent that can silently revert ten turns of work is worse than one that
/// cannot revert at all.
///
/// So a session-wide view has to be built from a different source, and can only make a weaker
/// claim. This reads the tool calls in the transcript: it can say *what was touched and when*, but
/// it holds no prior contents and therefore offers no undo. Git shows the actual diff. Saying that
/// plainly is the point — a session review that looked like the turn review but silently could not
/// restore anything would be the worse failure.
public enum SessionChangeSummary {

    public struct ChangedFile: Sendable, Equatable, Identifiable {
        public var path: String
        public var wrote: Bool
        public var edited: Bool
        public var deleted: Bool
        /// How many separate tool calls touched it.
        public var touches: Int
        public var lastTouchedAt: Date

        public var id: String { path }

        public var summary: String {
            var parts: [String] = []
            if deleted { parts.append("deleted") }
            if wrote { parts.append("written") }
            if edited { parts.append("edited") }
            if parts.isEmpty { parts.append("touched") }
            let times = touches == 1 ? "once" : "\(touches) times"
            return "\(parts.joined(separator: ", ")) — \(times)"
        }
    }

    private static let writeTools: Set<String> = ["file_write", "write_file", "create_file", "save_file"]
    private static let editTools: Set<String> = ["edit_file", "file_edit", "multi_edit", "edit_file_multi"]
    private static let deleteTools: Set<String> = ["file_delete", "delete_file", "rm"]

    /// Files the session's tool calls changed, most recently touched first.
    ///
    /// Only calls that actually succeeded count. A failed write changed nothing, and listing it
    /// would send a reviewer looking for a diff that does not exist.
    public static func changedFiles(in messages: [ChatMessage], workspaceRoot: String = "") -> [ChangedFile] {
        var byPath: [String: ChangedFile] = [:]

        for message in messages {
            for call in message.toolCalls {
                let name = ToolCallRepair.canonicalName(call.toolName)
                let isWrite = writeTools.contains(name)
                let isEdit = editTools.contains(name)
                let isDelete = deleteTools.contains(name)
                guard isWrite || isEdit || isDelete else { continue }
                guard call.status != .error, call.status != .failed else { continue }

                guard let raw = pathArgument(call.argumentsJson), !raw.isEmpty else { continue }
                let path = relative(raw, to: workspaceRoot)

                var entry = byPath[path] ?? ChangedFile(
                    path: path, wrote: false, edited: false, deleted: false,
                    touches: 0, lastTouchedAt: message.timestamp
                )
                entry.wrote = entry.wrote || isWrite
                entry.edited = entry.edited || isEdit
                entry.deleted = entry.deleted || isDelete
                entry.touches += 1
                entry.lastTouchedAt = max(entry.lastTouchedAt, message.timestamp)
                byPath[path] = entry
            }
        }

        return byPath.values.sorted {
            if $0.lastTouchedAt != $1.lastTouchedAt { return $0.lastTouchedAt > $1.lastTouchedAt }
            return $0.path < $1.path
        }
    }

    private static func pathArgument(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return (dict["path"] ?? dict["file_path"] ?? dict["filePath"] ?? dict["filename"] ?? dict["filepath"] ?? dict["file"]) as? String
    }

    private static func relative(_ path: String, to root: String) -> String {
        guard !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
