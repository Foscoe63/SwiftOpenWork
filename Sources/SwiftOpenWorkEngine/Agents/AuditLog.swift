import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// An append-only record of what an agent did and what was decided about it, one JSON object per
/// line, one file per chat under `audit/` in the app's data folder.
///
/// The transcript shows what the model said. It does not show that a command ran with nobody
/// watching, that a rule refused a call, or that a hook blocked one — and a Loop or a Shortcut
/// can run for an hour while you are away. This is the answer to "what happened, and who allowed it".
///
/// It is a record, not a source of state: nothing reads it back to drive the app. Arguments and
/// output are clipped, and secrets are scrubbed from both before they are written.
public final class AuditLog: @unchecked Sendable {
    public static let shared = AuditLog(directory: nil)

    public enum Decision: String, Sendable {
        /// Ran without asking: the approval level or a rule allowed it.
        case automatic
        case approved
        case rejected
        /// Needed a person, and the run was unattended.
        case refusedUnattended = "refused_unattended"
        case deniedByRule = "denied_by_rule"
        case blockedByHook = "blocked_by_hook"
    }

    private let lock = NSLock()
    private let overrideDirectory: URL?
    private let maxFieldCharacters = 2_000
    private let maxFileBytes = 8 * 1024 * 1024

    public init(directory: URL?) {
        self.overrideDirectory = directory
    }

    public var directory: URL {
        overrideDirectory ?? StorageService.shared.fileURL(for: "audit")
    }

    public func fileURL(sessionId: String) -> URL {
        let safe = sessionId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("\(safe.isEmpty ? "unknown" : safe).jsonl")
    }

    // MARK: - Writing

    public func record(sessionId: String?, event: String, fields: [String: Any] = [:]) {
        var line = fields
        line["event"] = event
        line["time"] = ISO8601DateFormatter().string(from: Date())
        line["session"] = sessionId ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: Self.clipped(line, limit: maxFieldCharacters), options: [.sortedKeys]) else { return }
        let url = fileURL(sessionId: sessionId ?? "unattributed")
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > maxFileBytes {
            // Keep the newest half rather than growing without bound.
            if let existing = try? Data(contentsOf: url) {
                let half = existing.index(existing.startIndex, offsetBy: existing.count / 2)
                if let cut = existing[half...].firstIndex(of: 0x0A) {
                    try? Data(existing[existing.index(after: cut)...]).write(to: url, options: .atomic)
                }
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    public func toolCall(
        sessionId: String?, tool: String, argumentsJson: String, decision: Decision,
        success: Bool? = nil, durationMs: Double? = nil, note: String? = nil
    ) {
        var fields: [String: Any] = [
            "tool": tool, "arguments": Self.scrub(argumentsJson), "decision": decision.rawValue,
        ]
        if let success { fields["success"] = success }
        if let durationMs { fields["duration_ms"] = Int(durationMs) }
        if let note { fields["note"] = Self.scrub(note) }
        record(sessionId: sessionId, event: "tool_call", fields: fields)
    }

    // MARK: - Reading

    /// The newest `limit` entries for a chat, oldest first.
    public func entries(sessionId: String, limit: Int = 200) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: fileURL(sessionId: sessionId), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    // MARK: - Scrubbing

    /// Secrets the agent may have typed or printed: API keys, bearer tokens, private-key blocks,
    /// and `KEY=value` assignments for names that say what they are.
    public static func scrubbed(_ text: String) -> String { scrub(text) }

    static func scrub(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in scrubbers {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    private static let scrubbers: [(String, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[private key]"),
        (#"\b(sk-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,})"#, "[key]"),
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{12,}"#, "$1 [token]"),
        (#"(?i)((?:api[_-]?key|secret|token|password|passwd|authorization)[\"']?\s*[:=]\s*[\"']?)[^\s\"',}]{4,}"#, "$1[redacted]"),
    ]

    private static func clipped(_ value: Any, limit: Int) -> Any {
        if let text = value as? String {
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        if let dict = value as? [String: Any] { return dict.mapValues { clipped($0, limit: limit) } }
        return value
    }
}
