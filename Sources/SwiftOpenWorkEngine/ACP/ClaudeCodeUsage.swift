import Foundation
import SwiftOpenWorkCore

/// What a Claude Code login has used, read from the transcripts Claude Code keeps in its config
/// folder (`<dir>/projects/**/*.jsonl`). Nothing is sent anywhere.
///
/// This is token counts, not the plan's limit meter: how much of a 5-hour or weekly allowance is
/// left is held by Anthropic's servers and is not on disk. `/status` and `/usage` inside Claude
/// Code itself show that.
public struct ClaudeCodeUsage: Sendable, Equatable {

    public struct Tokens: Sendable, Equatable {
        public var input = 0
        public var output = 0
        public var cacheWrite = 0
        public var cacheRead = 0
        public var messages = 0

        public var total: Int { input + output + cacheWrite + cacheRead }

        mutating func add(_ other: Tokens) {
            input += other.input; output += other.output
            cacheWrite += other.cacheWrite; cacheRead += other.cacheRead
            messages += other.messages
        }
    }

    public var configDir: String
    public var accountEmail: String?
    public var last5Hours = Tokens()
    public var today = Tokens()
    public var last7Days = Tokens()
    public var byModel: [(model: String, tokens: Tokens)] = []
    public var bySession: [String: Tokens] = [:]

    public static func == (a: Self, b: Self) -> Bool {
        a.configDir == b.configDir && a.accountEmail == b.accountEmail && a.last5Hours == b.last5Hours
            && a.today == b.today && a.last7Days == b.last7Days && a.bySession == b.bySession
    }

    // MARK: - Which folder

    public static let defaultConfigDir = NSHomeDirectory() + "/.claude"

    /// The config folder an external agent's Claude Code uses, or nil if the agent is not Claude Code.
    public static func configDir(for config: ExternalAgentConfig) -> String? {
        guard config.args.contains(where: { $0.contains("claude-code-acp") }) || config.command.hasSuffix("claude") else { return nil }
        return config.env["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath } ?? defaultConfigDir
    }

    /// Where `.claude.json` (which names the signed-in account) lives for a folder.
    static func accountFile(for configDir: String) -> String {
        configDir == defaultConfigDir ? NSHomeDirectory() + "/.claude.json" : configDir + "/.claude.json"
    }

    public static func accountEmail(configDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: accountFile(for: configDir)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    // MARK: - Reading

    /// Blocking: reads every transcript touched in the last 7 days. Call it off the main actor.
    public static func scan(configDir: String, now: Date = Date()) -> ClaudeCodeUsage {
        var result = ClaudeCodeUsage(configDir: configDir, accountEmail: accountEmail(configDir: configDir))
        let fm = FileManager.default
        let root = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3_600)
        let startOfToday = Calendar.current.startOfDay(for: now)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return result
        }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainStamp = ISO8601DateFormatter()
        var seen = Set<String>()
        var models: [String: Tokens] = [:]

        for case let file as URL in walker where file.pathExtension == "jsonl" {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < weekAgo { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let raw = object["timestamp"] as? String,
                      let when = stamp.date(from: raw) ?? plainStamp.date(from: raw) else { continue }
                // One reply is logged once per content block, with the same usage each time.
                let key = (message["id"] as? String ?? "") + "|" + (object["requestId"] as? String ?? "")
                if key != "|", !seen.insert(key).inserted { continue }

                let tokens = Tokens(
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    messages: 1
                )
                if tokens.total == 0 { continue }
                if let session = object["sessionId"] as? String { result.bySession[session, default: Tokens()].add(tokens) }
                guard when >= weekAgo else { continue }
                result.last7Days.add(tokens)
                if when >= startOfToday { result.today.add(tokens) }
                if when >= fiveHoursAgo { result.last5Hours.add(tokens) }
                models[(message["model"] as? String) ?? "unknown", default: Tokens()].add(tokens)
            }
        }
        result.byModel = models.map { ($0.key, $0.value) }.sorted { $0.tokens.total > $1.tokens.total }
        return result
    }

    // MARK: - One turn

    /// What one turn of a Claude Code session billed, for the composer's Sent / Recv. A turn with
    /// tool steps is many model calls, each re-sending the whole context (mostly as cache reads).
    public struct Turn: Sendable, Equatable {
        /// Prompt-side tokens summed over every call: fresh input plus cache writes plus cache reads.
        public var sent = 0
        public var received = 0
        /// The last call's prompt-side total, i.e. the context in use now.
        public var lastPrompt = 0
        public var calls = 0
    }

    /// Reads the session's transcript for the calls made since `since`. Blocking; nil when the
    /// transcript is missing or holds nothing for the turn, so the caller can fall back to an estimate.
    public static func turn(configDir: String, sessionId: String, since: Date) -> Turn? {
        let root = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainStamp = ISO8601DateFormatter()
        let cutoff = since.addingTimeInterval(-2)
        var turn = Turn()
        var seen = Set<String>()
        var latest = Date.distantPast
        for case let file as URL in walker where file.lastPathComponent == sessionId + ".jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let raw = object["timestamp"] as? String,
                      let when = stamp.date(from: raw) ?? plainStamp.date(from: raw), when >= cutoff else { continue }
                let key = (message["id"] as? String ?? "") + "|" + (object["requestId"] as? String ?? "")
                if key != "|", !seen.insert(key).inserted { continue }
                let prompt = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                let output = usage["output_tokens"] as? Int ?? 0
                if prompt + output == 0 { continue }
                turn.sent += prompt
                turn.received += output
                turn.calls += 1
                if when >= latest { latest = when; turn.lastPrompt = prompt }
            }
        }
        return turn.calls > 0 ? turn : nil
    }

    // MARK: - Showing

    public static func abbreviate(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    public static func line(_ t: Tokens) -> String {
        "\(abbreviate(t.total)) tokens · \(t.messages) replies (in \(abbreviate(t.input)), out \(abbreviate(t.output)), cache write \(abbreviate(t.cacheWrite)), cache read \(abbreviate(t.cacheRead)))"
    }

    /// Markdown for a chat message. `sessionId` is the agent's own session, when there is one.
    public func summary(sessionId: String?) -> String {
        var out = "### Claude Code usage\n"
        out += "- Account: \(accountEmail ?? "not signed in") (`\(configDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))`)\n"
        if let sessionId {
            out += "- This chat: \(Self.line(bySession[sessionId] ?? Tokens()))\n"
        }
        out += "- Last 5 hours: \(Self.line(last5Hours))\n"
        out += "- Today: \(Self.line(today))\n"
        out += "- Last 7 days: \(Self.line(last7Days))\n"
        if !byModel.isEmpty {
            out += "\nBy model, 7 days:\n" + byModel.prefix(5).map { "- `\($0.model)`: \(Self.abbreviate($0.tokens.total)) tokens" }.joined(separator: "\n") + "\n"
        }
        out += "\nToken counts come from this machine's transcripts. Your plan's remaining allowance is shown by `/usage` inside Claude Code."
        return out
    }
}
