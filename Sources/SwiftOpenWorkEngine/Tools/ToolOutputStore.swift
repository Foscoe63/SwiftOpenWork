import Foundation

/// Full text of tool results that were shortened before the model saw them.
///
/// Shortening is only safe if it can be undone: a log summary that dropped the one line the model
/// needed is worse than the long log. So whatever `ToolResultPipeline` cuts is kept here under a
/// short id, and `recall_output` reads it back by line range or by search.
///
/// In memory only, and bounded. These are transient working copies of command output, not
/// something to persist, and a session that is closed has no use for them.
public final class ToolOutputStore: @unchecked Sendable {
    public static let shared = ToolOutputStore()

    /// Oldest entries go first once the store holds more than this.
    public static let maxTotalBytes = 48 * 1024 * 1024
    public static let maxEntries = 200

    /// A recall answers with at most this much, so reading back never reintroduces the problem.
    public static let maxRecallChars = 12_000
    public static let defaultRangeLines = 120
    public static let maxRangeLines = 400
    public static let maxSearchMatches = 40
    public static let searchContextLines = 2
    static let maxLineChars = 400

    public struct Entry: Sendable {
        public let id: String
        public let toolName: String
        public let sessionId: String?
        public let text: String
        public let createdAt: Date

        public var lineCount: Int {
            text.isEmpty ? 0 : text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var totalBytes = 0

    public init() {}

    // MARK: - Storing

    /// Keep `text` and return the id the model uses to ask for it again.
    @discardableResult
    public func store(text: String, toolName: String, sessionId: String?) -> String {
        lock.lock(); defer { lock.unlock() }
        var id: String
        repeat { id = "out_" + String(UUID().uuidString.prefix(6)).lowercased() } while entries[id] != nil
        entries[id] = Entry(id: id, toolName: toolName, sessionId: sessionId, text: text, createdAt: Date())
        order.append(id)
        totalBytes += text.utf8.count
        while (totalBytes > Self.maxTotalBytes || order.count > Self.maxEntries), order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = entries.removeValue(forKey: oldest) { totalBytes -= gone.text.utf8.count }
        }
        return id
    }

    public func entry(_ id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    /// Newest first.
    public func recent(sessionId: String?, limit: Int = 10) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return order.reversed().compactMap { entries[$0] }
            .filter { sessionId == nil || $0.sessionId == nil || $0.sessionId == sessionId }
            .prefix(limit).map { $0 }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); order.removeAll(); totalBytes = 0
    }

    // MARK: - Reading back

    public struct Recall: Sendable, Equatable {
        public let success: Bool
        public let text: String
    }

    /// What `recall_output` returns. `query` wins over a line range when both are given.
    public func recall(id rawId: String, query: String?, start: Int?, lines: Int?, sessionId: String?) -> Recall {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return Recall(success: true, text: listing(sessionId: sessionId)) }
        guard let entry = entry(id) else {
            return Recall(
                success: false,
                text: "No saved output '\(id)'. It may have been evicted, or the id is misspelt.\n\(listing(sessionId: sessionId))"
            )
        }
        let all = entry.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = "[\(entry.id) · \(entry.toolName) · \(all.count) lines · \(entry.text.count) chars]"
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = trimmedQuery.isEmpty
            ? Self.range(of: all, start: start, lines: lines)
            : Self.search(all, query: trimmedQuery)
        return Recall(success: true, text: header + "\n" + body)
    }

    func listing(sessionId: String?) -> String {
        let items = recent(sessionId: sessionId)
        guard !items.isEmpty else { return "No tool output has been saved in this session." }
        return "Saved outputs (newest first):\n" + items.map {
            "- \($0.id): \($0.toolName), \($0.lineCount) lines, \($0.text.count) chars"
        }.joined(separator: "\n")
    }

    static func range(of lines: [String], start: Int?, lines count: Int?) -> String {
        guard !lines.isEmpty else { return "(empty)" }
        let first = min(max(1, start ?? 1), lines.count)
        let take = min(max(1, count ?? defaultRangeLines), maxRangeLines)
        let last = min(lines.count, first + take - 1)
        var out: [String] = []
        var used = 0
        var stoppedAt = last
        for number in first...last {
            let line = clip(lines[number - 1])
            used += line.count + 8
            if used > maxRecallChars { stoppedAt = number - 1; break }
            out.append("\(number)| \(line)")
        }
        var text = out.joined(separator: "\n")
        if stoppedAt < lines.count {
            text += "\n[showing lines \(first)–\(stoppedAt) of \(lines.count); pass start=\(stoppedAt + 1) for more]"
        }
        return text
    }

    static func search(_ lines: [String], query: String) -> String {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard !terms.isEmpty else { return range(of: lines, start: nil, lines: nil) }
        let lowered = lines.map { $0.lowercased() }
        var hits = lowered.indices.filter { i in terms.allSatisfy { lowered[i].contains($0) } }
        var mode = "all words"
        if hits.isEmpty {
            hits = lowered.indices.filter { i in terms.contains { lowered[i].contains($0) } }
            mode = "any word"
        }
        guard !hits.isEmpty else {
            return "No line contains \(terms.map { "'\($0)'" }.joined(separator: " or ")). Try fewer or different words, or read a range with start/lines."
        }
        let shownHits = Array(hits.prefix(maxSearchMatches))
        let hitSet = Set(shownHits)
        // Merge each hit's context into runs so overlapping windows print once.
        var keep = Set<Int>()
        for h in shownHits {
            for i in max(0, h - searchContextLines)...min(lines.count - 1, h + searchContextLines) { keep.insert(i) }
        }
        var out: [String] = []
        var used = 0
        var previous = -2
        for i in keep.sorted() {
            if i != previous + 1 { out.append("…") }
            let line = clip(lines[i])
            used += line.count + 8
            if used > maxRecallChars { out.append("[output limit reached; narrow the query]"); break }
            out.append("\(hitSet.contains(i) ? ">" : " ")\(i + 1)| \(line)")
            previous = i
        }
        let more = hits.count > shownHits.count ? " (showing the first \(shownHits.count))" : ""
        return "\(hits.count) matching line(s) for \(mode)\(more); '>' marks a match:\n" + out.joined(separator: "\n")
    }

    private static func clip(_ line: String) -> String {
        line.count > maxLineChars ? String(line.prefix(maxLineChars)) + "…" : line
    }
}

/// How much context the shortening saved, for the meter beside the composer.
///
/// Counted in characters at the same ~4 characters a token the composer's own estimate uses, so
/// the figure is not flattered by a more generous ratio.
public final class ContextSavings: @unchecked Sendable {
    public static let shared = ContextSavings()

    public static let charactersPerToken = 4

    private let lock = NSLock()
    private var characters: [String: Int] = [:]

    public init() {}

    public func record(sessionId: String?, savedCharacters: Int) {
        guard savedCharacters > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        characters[sessionId ?? "", default: 0] += savedCharacters
    }

    public func recordTokens(sessionId: String?, savedTokens: Int) {
        record(sessionId: sessionId, savedCharacters: savedTokens * Self.charactersPerToken)
    }

    public func tokensSaved(sessionId: String?) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (characters[sessionId ?? ""] ?? 0) / Self.charactersPerToken
    }

    public func reset(sessionId: String?) {
        lock.lock(); defer { lock.unlock() }
        characters.removeValue(forKey: sessionId ?? "")
    }
}
