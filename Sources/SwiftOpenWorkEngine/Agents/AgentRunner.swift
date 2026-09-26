import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

@MainActor
public final class AgentStreamAccumulator {
    public private(set) var message: ChatMessage
    public private(set) var fullText: String = ""
    public private(set) var fullReasoning: String = ""
    public private(set) var isLoopDetected: Bool = false
    private let startTime: CFAbsoluteTime
    private let onUpdate: (ChatMessage) -> Void
    private let isLoopBreakerEnabled: Bool
    /// Where the current ReAct iteration's output starts. The loop check looks only past these.
    private var textIterationStart = 0
    private var reasoningIterationStart = 0
    /// Stretches of `fullText` moved to Reasoning because tools followed them. Kept, rather than
    /// applied once, because every later render starts again from `fullText`: `finalize` used to
    /// re-publish the whole of it, so each hidden "Let me examine…" came back at the end of the
    /// turn — seven copies of the same heading in one reply.
    private var hiddenRanges: [Range<Int>] = []

    public init(initialMessage: ChatMessage, onUpdate: @escaping (ChatMessage) -> Void) {
        self.message = initialMessage
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.onUpdate = onUpdate
        self.isLoopBreakerEnabled = PersistenceManager.shared.loadSettings().autoLoopBreakerEnabled
    }

    /// Mark the start of a new model call within the turn.
    ///
    /// The turn's reasoning accumulates across every call, and each call naturally re-states its
    /// plan: "Let me start by getting today's date and exploring…" at step one and again at step
    /// two. Checking the whole accumulation read that as a loop and stopped a scheduled run after
    /// its first tool call. A loop is repetition within one generation.
    public func beginIteration() {
        textIterationStart = fullText.count
        reasoningIterationStart = fullReasoning.count
    }

    public func applyChunk(_ chunk: LLMStreamChunk) {
        if let notice = chunk.deltaNotice, !notice.isEmpty {
            appendNotice(notice)
        }
        if let deltaR = chunk.deltaReasoning {
            fullReasoning += deltaR
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            // The loop breaker has to watch reasoning, not only visible text.
            //
            // It was gated on `deltaText` being non-empty, which held while reasoning arrived
            // inline in the visible stream. Once `ReasoningChannel` started routing an
            // unclosed `<think>` block to `deltaReasoning`, `deltaText` stayed empty for the
            // whole turn and the breaker never ran — so a spiral produced 12,000 characters of
            // reasoning over 192 seconds with nothing on screen, and had to be stopped by hand.
            // This is precisely the case the breaker was built for: reasoning models spiral
            // where the visible text never grows.
            if self.isLoopBreakerEnabled && checkRepetitionLoop(in: String(fullReasoning.dropFirst(reasoningIterationStart))) {
                isLoopDetected = true
                message.isStreaming = false
                onUpdate(message)
                return
            }
        }
        if !chunk.deltaText.isEmpty {
            fullText += chunk.deltaText
            publishVisibleContent()

            // Repetition / degenerative loop check on incoming stream (respects user settings)
            if self.isLoopBreakerEnabled && checkRepetitionLoop(in: String(fullText.dropFirst(textIterationStart))) {
                isLoopDetected = true
                message.isStreaming = false
                onUpdate(message)
                return
            }
        }
        if let promptTok = chunk.promptTokens {
            message.promptTokens = promptTok
        }
        if let compTok = chunk.completionTokens {
            message.completionTokens = compTok
        }
        if let speed = chunk.generationTokensPerSecond {
            message.generationTokensPerSecond = speed
        }
        if chunk.isFinished {
            message.isStreaming = false
        }
        onUpdate(message)
    }

    private func checkRepetitionLoop(in text: String) -> Bool {
        Self.detectsRepetitionLoop(in: text)
    }

    /// Whether `text` has degenerated into repetition.
    ///
    /// `nonisolated` so the streaming callback can run it as tokens arrive, off the MainActor.
    /// Detecting the loop only after the model has finished is not breaking it — the user still
    /// waits for the whole budget to burn, which is what happened before this was callable here.
    ///
    /// Only the tail is examined. Every check below already looks at the end of the output, and
    /// re-splitting the entire transcript on every token made the cost grow with the answer.
    public nonisolated static func detectsRepetitionLoop(in fullText: String) -> Bool {
        let text = String(fullText.suffix(4000))
        guard text.count >= 150 else { return false }
        
        // 1. Check for exact repeating sentences or phrase patterns (30-150 chars repeating 3+ times at tail)
        for patternLen in [30, 40, 50, 60, 70, 80, 100, 120, 140] {
            guard text.count >= patternLen * 3 else { continue }
            let suffix3 = text.suffix(patternLen * 3)
            let s1 = suffix3.prefix(patternLen)
            let s2 = suffix3.dropFirst(patternLen).prefix(patternLen)
            let s3 = suffix3.suffix(patternLen)
            if s1 == s2 && s2 == s3 {
                return true
            }
        }
        
        // 2. Exact line-level repetition (3+ identical non-empty trimmed lines)
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 15 }
        
        if rawLines.count >= 4 {
            let last = rawLines.last!
            let count = rawLines.suffix(5).filter { $0 == last }.count
            if count >= 3 {
                return true
            }
        }

        // 3. Fuzzy / Semantic repetition check on recent lines
        //
        // One similar pair is ordinary writing — two bullets that start the same way, a heading and
        // its restatement. A loop keeps going, so it takes two similar pairs in a row: three
        // near-identical lines.
        if rawLines.count >= 3 {
            let recentLines = Array(rawLines.suffix(5))
            var similarRun = 0
            for i in 0..<(recentLines.count - 1) {
                let lineA = recentLines[i]
                let lineB = recentLines[i + 1]
                
                // Compare normalized word overlap / Jaccard similarity
                let wordsA = Set(lineA.lowercased().split(separator: " ").map { String($0) })
                let wordsB = Set(lineB.lowercased().split(separator: " ").map { String($0) })
                
                guard wordsA.count >= 6 && wordsB.count >= 6 else { similarRun = 0; continue }
                let commonWords = wordsA.intersection(wordsB)
                let unionWords = wordsA.union(wordsB)
                let similarity = Double(commonWords.count) / Double(unionWords.count)

                // Common prefix check (e.g. "Now I have today's date...")
                let prefixLen = zip(lineA.lowercased(), lineB.lowercased()).prefix(while: { $0 == $1 }).count
                let samePrefix = prefixLen >= 45 && prefixLen >= min(lineA.count, lineB.count) * 3 / 4

                if similarity >= 0.85 || samePrefix {
                    similarRun += 1
                    if similarRun >= 2 { return true }
                } else {
                    similarRun = 0
                }
            }
        }

        // 4. Repeated N-gram phrases in trailing window: an identical 8-word sequence 3+ times.
        //
        // This was 5 words, which natural text meets constantly: "by getting today's date and"
        // three times in a plan, "describes a distinct configuration value" down a list of
        // settings. Eight identical words, three times, in a thousand characters is a loop.
        let words = text.suffix(1000).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let gramLength = 8
        if words.count >= 20 {
            var ngrams: [String: Int] = [:]
            for i in 0..<(words.count - gramLength + 1) {
                let gram = words[i..<(i + gramLength)].joined(separator: " ")
                let currentCount = (ngrams[gram] ?? 0) + 1
                ngrams[gram] = currentCount
                if currentCount >= 3 {
                    return true
                }
            }
        }

        return false
    }

    public func addToolCall(_ toolCall: ToolCallInfo) {
        message.toolCalls.append(toolCall)
        onUpdate(message)
    }

    public func updateToolCall(_ toolCall: ToolCallInfo) {
        if let idx = message.toolCalls.firstIndex(where: { $0.id == toolCall.id }) {
            message.toolCalls[idx] = toolCall
        } else {
            message.toolCalls.append(toolCall)
        }
        onUpdate(message)
    }

    /// Show a delegated task on this message, or update it in place.
    public func upsertSubAgentTask(_ task: SubAgentTask) {
        if let idx = message.subAgentTasks.firstIndex(where: { $0.id == task.id }) {
            message.subAgentTasks[idx] = task
        } else {
            message.subAgentTasks.append(task)
        }
        onUpdate(message)
    }

    public func appendContent(_ text: String) {
        fullText += text
        publishVisibleContent()
        onUpdate(message)
    }

    public func appendNotice(_ notice: String) {
        guard !notice.isEmpty else { return }
        // Avoid stacking identical status chips.
        if message.notices.last == notice { return }

        // Progress updates supersede rather than accumulate. Skipping only *identical* notices
        // does nothing for a counter: "Loading MLX weights: 21%" and "…: 22%" differ, so a 50GB
        // load left one permanent chip per percent. A real export carried sixteen of them, and
        // that load had only reached 36%.
        if let last = message.notices.last, Self.progressFamily(last) != nil,
           Self.progressFamily(last) == Self.progressFamily(notice) {
            message.notices[message.notices.count - 1] = notice
            onUpdate(message)
            return
        }

        message.notices.append(notice)
        onUpdate(message)
    }

    /// The stable part of a progress notice, or nil when it is not one.
    ///
    /// Two notices belong to the same progress run when they differ only in a trailing number, so
    /// "Loading MLX weights: 21%" and "Loading MLX weights: 22%" collapse while "MCP ready" and
    /// "Plan mode exited." stay as separate chips.
    public static func progressFamily(_ notice: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[\d.]+\s*%\s*$"#) else { return nil }
        let range = NSRange(location: 0, length: (notice as NSString).length)
        guard regex.firstMatch(in: notice, range: range) != nil else { return nil }
        return regex.stringByReplacingMatches(in: notice, options: [], range: range, withTemplate: "")
    }

    /// Recover stream text if fire-and-forget MainActor chunk tasks lagged behind the provider.
    public func reconcileFromBridge(text: String, reasoning: String, promptTokens: Int, completionTokens: Int) {
        if text.count > fullText.count {
            fullText = text
            publishVisibleContent()
        }
        if reasoning.count > fullReasoning.count {
            fullReasoning = reasoning
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        if promptTokens > 0 {
            message.promptTokens = promptTokens
        }
        if completionTokens > 0 {
            message.completionTokens = completionTokens
        }
        onUpdate(message)
    }

    public func setHalt(reason: String, text: String) {
        message.haltReason = reason
        message.haltText = text
        message.isStreaming = false
        if !text.isEmpty {
            fullText += (fullText.isEmpty ? "" : "\n\n") + text
            publishVisibleContent()
        }
        onUpdate(message)
    }

    public func handleError(_ error: Error) {
        message.isStreaming = false
        message.isError = true
        publishVisibleContent()
        if message.content.isEmpty {
            message.content = "Error: \(error.localizedDescription)"
        }
        onUpdate(message)
    }

    /// Split leaked model thinking out of the visible bubble; keep raw `fullText` for tool parsing.
    private func publishVisibleContent() {
        var split = AssistantContentSanitizer.splitThinking(from: visibleSourceText)
        split.thinking = AssistantContentSanitizer.stripControlTokens(split.thinking)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !split.thinking.isEmpty {
            if fullReasoning.isEmpty {
                fullReasoning = split.thinking
            } else if !fullReasoning.contains(split.thinking) && !split.thinking.contains(fullReasoning) {
                fullReasoning += (fullReasoning.hasSuffix("\n") ? "" : "\n") + split.thinking
            } else if split.thinking.count > fullReasoning.count {
                fullReasoning = split.thinking
            }
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        message.content = AssistantContentSanitizer.sanitizeVisible(split.visible)
    }

    /// `fullText` without the narration hidden so far.
    private var visibleSourceText: String {
        guard !hiddenRanges.isEmpty else { return fullText }
        var out = ""
        var cursor = 0
        let characters = Array(fullText)
        for range in hiddenRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = min(max(range.lowerBound, cursor), characters.count)
            let upper = min(range.upperBound, characters.count)
            if lower > cursor { out += String(characters[cursor..<lower]) }
            cursor = max(cursor, upper)
        }
        if cursor < characters.count { out += String(characters[cursor...]) }
        return out
    }

    public func cleanToolCallSyntax(from rawText: String) -> String {
        let split = AssistantContentSanitizer.splitThinking(from: rawText)
        return AssistantContentSanitizer.sanitizeVisible(split.visible)
    }

    public func finalize() {
        message.isStreaming = false
        publishVisibleContent()
        recoverAnswerFromReasoningIfBlank()
        // Drop routine MCP status chips once the answer is on screen.
        message.notices.removeAll { notice in
            let n = notice.lowercased()
            return n.contains("loading mlx weights")
                || n.contains("loading local mlx weights")
                || n.contains("downloading mlx weights")
                || n.contains("listing configured mcp")
                || n.contains("mcp ready")
                || n.contains("warming mcp")
                || n.contains("connecting ")
                || n.hasPrefix("connecting")
        }
        onUpdate(message)
    }

    /// A turn that produced only reasoning must not render as an empty bubble.
    ///
    /// `hideTurnNarration` moves a narrated preamble into Reasoning and resets the visible text,
    /// on the assumption that a final answer still follows. When the turn ends instead — a
    /// reasoning-heavy local model that never closed its think block, or a loop that was cut off —
    /// the user is left with nothing on screen while the model plainly said something. Showing the
    /// tail of what it said, labelled, beats showing silence.
    private func recoverAnswerFromReasoningIfBlank() {
        guard message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The error path states its own case; a halt has already appended its text.
        guard !message.isError else { return }

        let reasoning = fullReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reasoning.isEmpty {
            let tail = String(reasoning.suffix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
            message.content = """
            *(The model produced no separate answer, only its own reasoning. Its closing thoughts:)*

            \(tail)
            """
            return
        }

        // Nothing at all: no answer, no reasoning, no halt, no error. Seen for real — a Llama
        // model answered "Good Day" with three identical date lookups and then a bare
        // `<|python_tag|>`, which is a tool-call marker with no call behind it. An empty bubble
        // is indistinguishable from the app having broken, so say which happened.
        let ranTools = !message.toolCalls.isEmpty
        message.content = ranTools
            ? "*(The model ran tools but ended its turn without writing an answer. The tool results are above; ask it to summarise them, or try again.)*"
            : "*(The model ended its turn without producing any output. Try again, or switch models.)*"
    }

    /// When the model narrates then emits tools, hide that preamble in the bubble (keep raw text for parsing).
    public func hideTurnNarration(beforeLength: Int) {
        let delta = String(fullText.dropFirst(beforeLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !delta.isEmpty else {
            publishVisibleContent()
            onUpdate(message)
            return
        }
        let split = AssistantContentSanitizer.splitThinking(from: delta)
        let narrate = AssistantContentSanitizer.sanitizeVisible(split.visible)
        let think = [split.thinking, narrate].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !think.isEmpty {
            if fullReasoning.isEmpty {
                fullReasoning = think
            } else if !fullReasoning.contains(think) {
                fullReasoning += "\n\n" + think
            }
            message.reasoning = fullReasoning
            message.thinkingTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        }
        // Show only content from before this step until the final answer lands, and keep it
        // hidden when the turn is re-rendered later.
        hiddenRanges.append(beforeLength..<fullText.count)
        publishVisibleContent()
        onUpdate(message)
    }

    /// What one step of the turn said, starting at `offset` in `fullText`, sanitized for feeding
    /// back to the model as that step's assistant message.
    ///
    /// This used to be the whole turn's text, fed back after every step, so by step eight the
    /// model was shown its own opening paragraph eight times — and repeated it.
    public func stepText(from offset: Int) -> String {
        cleanToolCallSyntax(from: String(fullText.dropFirst(offset)))
    }
}

/// Strips leaked chain-of-thought and tool-call markup from user-visible assistant text.
public enum AssistantContentSanitizer {
    public static func splitThinking(from raw: String) -> (visible: String, thinking: String) {
        var text = raw
        var thinkingParts: [String] = []

        func extractBlocks(pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
            let ns = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let bodyRange = Range(match.range(at: 1), in: text) else { continue }
                let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { thinkingParts.insert(body, at: 0) }
                if let full = Range(match.range(at: 0), in: text) {
                    text.removeSubrange(full)
                }
            }
        }

        extractBlocks(pattern: #"<think>\s*([\s\S]*?)\s*</think>"#)
        extractBlocks(pattern: #"<thinking>\s*([\s\S]*?)\s*</thinking>"#)
        extractBlocks(pattern: #"<redacted_reasoning>\s*([\s\S]*?)\s*</redacted_reasoning>"#)

        // Qwen / Ornith often emit preamble then a bare </think> with no opener.
        let closeTags = ["</think>", "</thinking>", "</redacted_reasoning>"]
        for tag in closeTags {
            if let range = text.range(of: tag, options: .backwards) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = String(text[range.upperBound...])
                if !before.isEmpty { thinkingParts.append(before) }
                text = after
                break
            }
        }

        // Incomplete streaming think block — hide until closed.
        for open in ["<think>", "<thinking>", "<redacted_reasoning>"] {
            if let openRange = text.range(of: open, options: .backwards) {
                let before = String(text[..<openRange.lowerBound])
                let inside = String(text[openRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inside.isEmpty { thinkingParts.append(inside) }
                text = before
                break
            }
        }

        let thinking = thinkingParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (text, thinking)
    }

    /// Chat-template control tokens, e.g. Llama's `<|python_tag|>` / `<|eot_id|>` and Qwen's
    /// `<|im_start|>`.
    ///
    /// These are template scaffolding, not content. When a model emits one the tokenizer did not
    /// consume — Llama 3 marks a tool call with `<|python_tag|>` — it lands in the answer verbatim,
    /// and a user who said "Good Day" gets `<|python_tag|>` back as the entire reply.
    ///
    /// Stripping matters beyond display: this text is fed back as conversation history, and a
    /// stray control token in a rendered prompt is not inert.
    ///
    /// The shape is `<|` identifier `|>`, which is deliberately narrow — prose does not contain it.
    private static let controlTokenPattern = #"<\|[A-Za-z0-9_\-]{1,40}\|>"#

    public static func stripControlTokens(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: controlTokenPattern) else { return raw }
        let range = NSRange(location: 0, length: (raw as NSString).length)
        return regex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
    }

    public static func sanitizeVisible(_ raw: String) -> String {
        var cleaned = stripControlTokens(raw)

        // Remove TOOL_CALL = { ... }
        let assignPattern = "TOOL_CALL\\s*=\\s*\\{[\\s\\S]*?\\}"
        if let regex = try? NSRegularExpression(pattern: assignPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Remove ```tool_call ... ``` or ```json with tool definitions
        let codeBlockPattern = "```(?:tool_call|json)?\\s*(?:\\r?\\n)?\\s*\\{\\s*\"(?:tool|name|mcp|server)\"[\\s\\S]*?\\}\\s*(?:\\r?\\n)?```"
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Remove XML tool calls <tool_call>...</tool_call>
        let xmlPattern = "<tool_call>[\\s\\S]*?(?:</tool_call>|$)"
        if let regex = try? NSRegularExpression(pattern: xmlPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Remove raw naked tool JSON if it was the entirety or beginning of a line
        let nakedPattern = "(?m)^\\s*\\{\\s*\"(?:tool|name|mcp|server)\"\\s*:[\\s\\S]*?\\}\\s*$"
        if let regex = try? NSRegularExpression(pattern: nakedPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Remove leftover think tag crumbs and filler intent lines.
        let crumbPattern = "(?i)</?think>|</?thinking>|</?redacted_reasoning>"
        if let regex = try? NSRegularExpression(pattern: crumbPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        let fillerLinesPattern = "(?m)^\\s*(?:Let me emit tool calls\\.?|Let me call the tool\\.?|---\\s*)$\\s*"
        if let regex = try? NSRegularExpression(pattern: fillerLinesPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        cleaned = dedupeRepeatedParagraphs(cleaned)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses consecutive near-duplicate paragraphs (common with leaked monologue).
    private static func dedupeRepeatedParagraphs(_ text: String) -> String {
        let parts = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return text }

        var out: [String] = []
        for part in parts {
            if let last = out.last, paragraphsNearlyEqual(last, part) {
                if part.count > last.count { out[out.count - 1] = part }
                continue
            }
            out.append(part)
        }
        return out.joined(separator: "\n\n")
    }

    private static func paragraphsNearlyEqual(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        if na.count >= 40, nb.count >= 40 {
            if na.hasPrefix(nb) || nb.hasPrefix(na) { return true }
            let wa = Set(na.split(separator: " ").map(String.init))
            let wb = Set(nb.split(separator: " ").map(String.init))
            guard wa.count >= 8, wb.count >= 8 else { return false }
            let inter = Double(wa.intersection(wb).count)
            let union = Double(wa.union(wb).count)
            return union > 0 && inter / union >= 0.9
        }
        return false
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
public final class SubAgentAccumulator {
    public var text: String = ""
    public init() {}
    public func append(_ delta: String) {
        text += delta
    }
}

/// Thread-safe collector for native tool calls emitted from provider stream callbacks
/// (which often run off the MainActor).
final class AgentToolCallCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ToolCallInfo] = []

    /// Streaming providers send one call as a run of growing snapshots — the first often has an
    /// empty `arguments` — all under the same id. The latest snapshot is the complete one, so an
    /// id already held is *replaced*, keeping its position. This used to keep the first snapshot
    /// and drop the rest, so a call streamed in fragments ran with empty or truncated arguments.
    func add(_ tc: ToolCallInfo) {
        lock.lock()
        defer { lock.unlock() }
        if let index = items.firstIndex(where: { $0.id == tc.id }) {
            items[index] = tc
        } else if !items.contains(where: { $0.toolName == tc.toolName && $0.argumentsJson == tc.argumentsJson }) {
            items.append(tc)
        }
    }

    func snapshot() -> [ToolCallInfo] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

}

/// Thread-safe collector for the thinking blocks one model response produced, in order.
final class AgentThinkingBlockCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [ThinkingBlock] = []

    func add(_ block: ThinkingBlock) {
        lock.lock()
        defer { lock.unlock() }
        blocks.append(block)
    }

    /// Nil when there were none, so the message stays as it always was.
    func snapshot() -> [ThinkingBlock]? {
        lock.lock()
        defer { lock.unlock() }
        return blocks.isEmpty ? nil : blocks
    }
}

/// A thread-safe "every Nth call" gate, for work too costly to do per token.
public final class StreamTickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public func tick(every n: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        guard count >= n else { return false }
        count = 0
        return true
    }
}

/// Aggregates stream text off the MainActor so a delayed UI Task cannot lose the turn.
private final class AgentStreamTextBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var reasoning = ""
    private var completionTokens = 0
    private var promptTokens = 0

    func ingest(_ chunk: LLMStreamChunk) {
        lock.lock()
        defer { lock.unlock() }
        if !chunk.deltaText.isEmpty {
            text += chunk.deltaText
        }
        if let r = chunk.deltaReasoning, !r.isEmpty {
            reasoning += r
        }
        if let c = chunk.completionTokens {
            completionTokens = c
        }
        if let p = chunk.promptTokens {
            promptTokens = p
        }
    }

    func snapshot() -> (text: String, reasoning: String, promptTokens: Int, completionTokens: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (text, reasoning, promptTokens, completionTokens)
    }

    /// The tail of the visible text, for the repetition check.
    func textTail(_ count: Int = 4000) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(text.suffix(count))
    }

    /// A reasoning-heavy model spirals inside its think block, where the visible text never grows.
    /// Watching only `deltaText` would let exactly that run to the end of the token budget.
    func reasoningTail(_ count: Int = 4000) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(reasoning.suffix(count))
    }
}

/// Lets the streaming callback stop the generation it is reading.
///
/// The loop detector used to set a flag that was only read *after* the stream finished, so a
/// degenerating model still burned its whole token budget — 219 seconds, in the run that prompted
/// this — before anything acted on it. Detecting a runaway and then waiting for it is not breaking
/// it. Cancelling works because the MLX generation loop checks `Task.isCancelled` between tokens.
private final class AgentStreamStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var stopRequested = false
    private var reason: String?

    /// Attach the task once it exists. If the stop already fired — possible, since the first
    /// chunks can arrive before this returns — cancel immediately rather than losing the request.
    func attach(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        let alreadyStopped = stopRequested
        lock.unlock()
        if alreadyStopped { task.cancel() }
    }

    func stop(reason: String) {
        lock.lock()
        guard !stopRequested else { lock.unlock(); return }
        stopRequested = true
        self.reason = reason
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    var stoppedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

/// Text accumulated off the main actor.
///
/// `SubAgentAccumulator` is `@MainActor`, which was fine while sub-agents ran one at a time on
/// the main actor and is not once their streams fan out across a task group.
public final class ConcurrentTextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    public init() {}
    public func append(_ text: String) {
        lock.lock(); buffer += text; lock.unlock()
    }
    public var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

@MainActor
public final class AgentRunner {

    /// What the model is told about a tool call, success or not.
    ///
    /// A failing tool used to be reduced to `"Error: \(error)"`, discarding `output` entirely —
    /// so any tool that reports a failure *and* explains it lost the explanation at exactly the
    /// moment it mattered. `run_app` hit this live: an app that exited non-zero produced
    /// "Error: unknown error", with the exit code, stdout and stderr all thrown away.
    public static func describeToolResult(_ result: ToolExecutionResult) -> String {
        if result.success { return result.output }
        let reason = result.error ?? "the tool reported failure without giving a reason"
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Error: \(reason)" : "Error: \(reason)\n\n\(detail)"
    }

    public static let shared = AgentRunner()

    private init() {}

    public func run(
        session: Session,
        agent: Agent,
        provider: ModelProvider,
        model: ModelInfo,
        workspace: Workspace,
        allAgents: [Agent],
        reasoningOverride: ReasoningEffort? = nil,
        onMessageUpdated: @escaping (ChatMessage) -> Void,
        onSubAgentTaskCreated: @escaping (SubAgentTask) -> Void,
        onSubAgentTaskUpdated: @escaping (SubAgentTask) -> Void,
        onInterAgentMessage: @escaping (AgentMessage) -> Void,
        onSessionTodosUpdated: (([SessionTodoItem]) -> Void)? = nil,
        onModelContextUpdated: ((ModelContextSnapshot) -> Void)? = nil
    ) async {
        // The chat composer's "Reasoning" pill overrides the agent's own configured effort for
        // this turn when set; nil (no override) preserves the agent's own setting.
        let effectiveReasoningEffort = reasoningOverride ?? agent.reasoningEffort
        let assistantMsgId = UUID().uuidString
        let assistantMsg = ChatMessage(
            id: assistantMsgId,
            sessionId: session.id,
            role: .assistant,
            content: "",
            agentId: agent.id,
            agentName: agent.name,
            agentAvatar: agent.avatar,
            agentColor: agent.color,
            modelId: model.id,
            providerId: provider.id,
            timestamp: Date(),
            isStreaming: true
        )

        onMessageUpdated(assistantMsg)

        let lastPrompt = session.messages.last(where: { $0.role == .user })?.content ?? ""

        // Delegation is the model's decision, made with `agent_spawn`.
        //
        // This used to be decided by keywords: any prompt containing "build", "create", "project",
        // "research", "analyze", "agent", "team", "subagent" or "refactor" sent the *whole prompt*
        // to the first two team members at once, before the lead did anything, each with a
        // six-step budget. "Create a note" was enough. On a single local model that meant
        // re-reading the prompt for every agent switch and two budget-starved copies of the same
        // job — a scheduled brief took over ten minutes and its research sub-agent ran out of
        // steps every time. The lead is now told who its team is and delegates a specific
        // sub-task when one is worth handing off; see `teamPromptSection`.

        // 2. Stream Response & Execute Autonomous Multi-Turn ReAct Loop (Up to configurable iterations)
        let accumulator = AgentStreamAccumulator(
            initialMessage: assistantMsg,
            onUpdate: onMessageUpdated
        )
        defer {
            // Never leave a bubble stuck on isStreaming after cancel / MCP hang recovery.
            if accumulator.message.isStreaming {
                accumulator.finalize()
            }
        }

        let loadedSettings = PersistenceManager.shared.loadSettings()
        let maxIterations = max(1, loadedSettings.maxAutonomousIterations)
        let maxTurnTokens = max(1, loadedSettings.maxTurnTokens)
        var planModeActive = loadedSettings.planModeEnabled
        var availableTools = PersistenceManager.shared.loadTools().filter { $0.isEnabled }
        _ = ToolSchemaCatalog.ensureParityTools(in: &availableTools)

        // Casual / inventory turns must not wait on npx cold starts.
        let casualChat = MCPClientManager.isCasualChatPrompt(lastPrompt)
        let inventoryPrompt = MCPClientManager.isMCPInventoryPrompt(lastPrompt)
        let preferMCP = MCPClientManager.preferredServerIds(
            forPrompt: lastPrompt,
            servers: loadedSettings.mcpServers
        )
        let mcpTools: [Tool]
        if casualChat || inventoryPrompt {
            mcpTools = await MCPClientManager.shared.cachedMcpToolDefs()
            await MCPClientManager.shared.warmAllInBackground()
        } else if !preferMCP.isEmpty {
            // Brief wait only for the servers the prompt actually needs — no status chip spam.
            mcpTools = await MCPClientManager.shared.mcpToolDefs(
                preferServerIds: preferMCP,
                perServerTimeout: .seconds(8),
                overallTimeout: .seconds(6),
                blockForWarm: true
            )
        } else {
            // Cache-first: never stall the bubble on every enabled npx server.
            mcpTools = await MCPClientManager.shared.mcpToolDefs(
                preferServerIds: preferMCP,
                perServerTimeout: .seconds(8),
                overallTimeout: .seconds(6),
                blockForWarm: false
            )
        }

        var mcpPromptSummary = ""
        if inventoryPrompt {
            // Inventory: compact status only — no tool dump, no tool calling.
            let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
            let liveLines = reports.map { r -> String in
                let state: String
                if !r.enabled { state = "disabled" }
                else if r.connected { state = "connected (\(r.toolCount) tools)" }
                else if let err = r.error { state = "error: \(err)" }
                else { state = "not connected yet" }
                return "| \(r.name) | `\(r.id)` | \(r.transport) | \(state) |"
            }
            mcpPromptSummary = """

            ### MCP inventory (answer from this only)
            | Server | ID | Transport | Status |
            |--------|----|-----------|--------|
            \(liveLines.isEmpty ? "| _(none configured)_ | | | |" : liveLines.joined(separator: "\n"))

            INVENTORY MODE: Reply with one short markdown table of the servers above. \
            Do not call tools. Do not narrate your plan. Do not invent servers.
            """
            availableTools = []
        } else if !mcpTools.isEmpty {
            for t in mcpTools {
                if !availableTools.contains(where: { $0.id == t.id || $0.name == t.name }) {
                    availableTools.append(t)
                }
            }
            // Compact listing — avoid dumping every tool schema twice into the prompt.
            let byServer = Dictionary(grouping: mcpTools) { tool -> String in
                MCPNamespacedTool.parse(tool.name)?.serverId ?? "mcp"
            }
            let lines = byServer.map { serverId, tools -> String in
                let serverName = loadedSettings.mcpServers.first(where: { $0.id == serverId })?.name ?? serverId
                let leafNames = tools.compactMap { MCPNamespacedTool.parse($0.name)?.toolName ?? $0.name }
                    .sorted()
                let shown = leafNames.prefix(10).joined(separator: ", ")
                let more = leafNames.count > 10 ? " (+\(leafNames.count - 10) more)" : ""
                return "- **\(serverName)** (`\(serverId)`): \(shown)\(more)"
            }.sorted()
            mcpPromptSummary = """

            ### MCP tools (\(mcpTools.count) live) — call as `mcp__SERVER_ID__TOOL_NAME`
            \(lines.joined(separator: "\n"))
            Prefer native tool calls. Do not narrate before calling. Servers that expose only `get_tool_definitions` and `call_tool_by_name` need the catalog listed first; their catalog tools then become directly callable.
            """
        } else if !casualChat && !loadedSettings.mcpServers.filter(\.isEnabled).isEmpty {
            mcpPromptSummary = """

            ### MCP
            Enabled servers are still warming. Use built-in tools; do not invent MCP tool names.
            """
        }

        if planModeActive && !inventoryPrompt {
            availableTools = Self.filterToolsForPlanMode(availableTools)
        }

        // Offer the agent tools only to an agent allowed to use them, so the model is not handed
        // a tool whose every call is refused.
        let canDelegate = AgentRunner.subAgentSpawningAllowed(agent: agent, settings: loadedSettings)
            && AgentRunContext.depthLimit(for: agent, settings: loadedSettings) >= 1
        availableTools.removeAll { tool in
            (tool.name == "agent_spawn" && !canDelegate)
                || (tool.name == "agent_message" && !agent.canCommunicateWithOthers)
        }
        let teamSection = (inventoryPrompt || !canDelegate)
            ? ""
            : Self.teamPromptSection(
                agent: agent, allAgents: allAgents, provider: provider,
                budget: (steps: max(1, loadedSettings.subAgentStepBudget), minutes: max(1, loadedSettings.subAgentTimeoutMinutes))
            )

        // Undo is scoped to one turn, so the window opens here rather than at session start.
        await FileCheckpointStore.shared.beginTurn(label: session.id)

        // Standing rules that live in the repository itself.
        let instructionsSection = inventoryPrompt
            ? ""
            : ProjectInstructions.promptBlock(ProjectInstructions.load(folderPath: workspace.folderPath))

        // Where the agent actually is. Without this it guesses paths and build commands every turn.
        let workspaceSection = inventoryPrompt
            ? ""
            : WorkspaceContext.promptBlock(WorkspaceContext.snapshot(folderPath: workspace.folderPath))

        let enabledSkills = PersistenceManager.shared.loadSkills().filter(\.isEnabled)
        var skillsSection = ""
        // Skip skills dump on inventory — it only encourages digression.
        if !enabledSkills.isEmpty && !inventoryPrompt {
            let skillLines = enabledSkills.map { skill -> String in
                let body = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = body.isEmpty ? skill.description : String(body.prefix(160))
                return "- **\(skill.name)**: \(preview)"
            }
            skillsSection = """

            ### Active Skills
            \(skillLines.joined(separator: "\n"))
            """
        }

        // Skills that ship with the repository itself. Read from disk every turn, so editing one
        // takes effect on the next message without an import step.
        if !inventoryPrompt {
            skillsSection += ProjectSkills.promptBlock(
                ProjectSkills.load(workspacePath: workspace.folderPath)
            )
        }

        var iteration = 0
        // Continue from the transcript the model saw last turn, so the local engine's cache
        // extends it instead of re-reading the whole conversation (see `Session.modelHistory`).
        var workingMessages = session.modelHistory()
        // The last step's reply, when the turn ended on an answer rather than on tool calls.
        var finalStepText: String?

        var turnPromptTokens = 0
        var turnCompletionTokens = 0
        var identicalToolCounts: [String: Int] = [:]
        /// Signatures of calls parsed from the model's text and already sent to run this turn.
        var textCallsAlreadyRun = Set<String>()
        var askUserStreak = 0
        var halted = false
        var finishedNaturally = false
        // Set when a tool result this iteration marked settled progress — a green test run, a
        // clean tree — which is the cheapest moment to compact.
        var reachedMilestoneThisIteration = false
        // Consecutive MCP results that will not finish the job by being retried. Escalates to a
        // nudge, then to pulling MCP out of the tool list for the rest of the turn.
        var mcpDeadEnds = 0
        var warnedMcpStall = false
        /// Consecutive failures per (tool, arguments) pair, for `identicalFailureLimit`.
        var repeatedFailures: [String: Int] = [:]
        /// Successful file reads this turn, by call signature, for `unchangedReadNote`.
        var readLog: [String: RecordedRead] = [:]
        var mcpDisabledThisTurn = false

        // Promotion is turn-scoped: a catalog harvested against an earlier server set must not
        // leak into this turn as callable tools that no longer resolve.
        await MCPPromotedToolRegistry.shared.reset()

        // System prompt with modern tool-calling instructions (supports both native API tools & markdown ReAct schemas)
        let systemPromptWithTools: String
        if inventoryPrompt {
            systemPromptWithTools = """
            \(agent.systemPrompt)
            \(mcpPromptSummary)

            Be concise. No tool calls. No planning narration. Answer with one short table only.
            """
        } else {
            systemPromptWithTools = """
            \(agent.systemPrompt)
            \(workspaceSection)
            \(instructionsSection)

            You are an advanced, fully autonomous coding, systems, and research agent.
            Built-in tools (prefer native function/tool calling):
            file_read (supports offset/limit), file_write, edit_file, multi_edit, file_list, grep, glob,
            find_symbol, rename_symbol, build_project, run_tests,
            go_to_definition, find_references, symbol_info, code_diagnostics, document_symbols, call_hierarchy,
            setup_xcode_language_server,
            git_status, git_diff, git_log, changed_files, revert_changes,
            file_copy, file_move, file_delete,
            terminal_command/run_command, fetch_url, web_search, ask_user, exit_plan_mode,
            todo_write, calculator, get_current_date, document_extract,
            preview_start, preview_check, preview_logs, preview_stop,
            gmail_list, gmail_search, google_calendar_list, google_calendar_upcoming.
            \(mcpPromptSummary)
            \(skillsSection)
            \(teamSection)

            CRITICAL:
            0. When you change code: locate it with grep/glob rather than guessing, then verify with
               build_project (and run_tests when behaviour changed) before saying it is done. A
               compiler error is yours to fix, not to report. If an edit goes wrong, revert_changes
               undoes everything this turn touched.
               For a web UI, compiling is not seeing: start it once with preview_start, then run
               preview_check after each change and fix what its console errors and screenshot show.
               Never start a dev server with terminal_command — it is killed after two minutes.
               Before changing a function's signature or behaviour, find_references shows every
               caller; code_diagnostics checks one edited file in seconds.
            Editing well is most of the job:
               - Read the region immediately before you edit it; file_read prefixes every line with
                 its number and a tab — that prefix is not part of the file, so leave it out of
                 old_string.
               - Keep old_string short (2-6 lines) but unique, copied exactly from what you just read.
                 Use multi_edit for several changes to one file, and file_write only for new files
                 or full rewrites.
               - If an edit fails, the error says where your old_string stopped matching. Re-read that
                 region and copy it — do not retry variations from memory, and do not guess line
                 numbers.
               - If the same error survives two attempts, stop patching. Re-read the error and the
                 surrounding code, and change approach.
               - Swift: "the compiler is unable to type-check this expression in reasonable time"
                 means one expression is too complex. Break it into separate `let` values with
                 explicit types; do not restructure the code around it.
            1. Do not narrate ("I will check…" / "Let me…"). Call the tool immediately, then answer.
            2. Prefer native tool calls. Markdown fallback only if needed:
            ```tool_call
            {"tool": "file_list", "parameters": {"path": "."}}
            ```
            3. After tools finish, give one clear concise report — no repeated self-talk.
            \(planModeActive ? "\n5. PLAN MODE: do not mutate files or run shell. Propose a plan, then `exit_plan_mode` after approval." : "")
            """
        }

        while iteration < maxIterations {
            if Task.isCancelled {
                accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
                halted = true
                break
            }

            iteration += 1

            // Only under real context pressure: every fold rewrites history, and a local model's
            // KV cache cannot continue through a rewrite, so each one is a full re-read. See
            // `ContextCompactor.foldOldToolResults`.
            workingMessages = ContextCompactor.foldOldToolResults(
                workingMessages,
                pressure: (
                    estimatedTokens: ContextCompactor.estimatedTokens(
                        workingMessages, extraCharacters: systemPromptWithTools.count
                    ),
                    windowTokens: model.contextWindow
                )
            )

            // A milestone reached this iteration — a green build or test run, a clean tree — means
            // the work behind it is settled. Compacting here trades detail for room at the
            // cheapest possible moment, instead of waiting for the token budget to force it at a
            // worse one, mid-task.
            //
            // It does cost one KV cache rebuild: rewriting history is exactly what
            // `MLXSessionReuse` refuses to continue through, and correctly so. The rebuild is over
            // the *compacted* prefix, though, so it is cheaper than the prefill that would have
            // been paid on the uncompacted one — and it happens at a milestone rather than
            // mid-task.
            if loadedSettings.autoCompactContext, reachedMilestoneThisIteration {
                let compacted = ContextCompactor.compactAtMilestone(workingMessages)
                workingMessages = compacted.messages
                if compacted.didCompact {
                    accumulator.appendNotice("Milestone reached — earlier steps compacted.")
                }
            }
            reachedMilestoneThisIteration = false

            if loadedSettings.autoCompactContext {
                let compacted = ContextCompactor.compactIfNeeded(
                    workingMessages,
                    thresholdTokens: loadedSettings.contextCompactionThresholdTokens
                )
                workingMessages = compacted.messages
                if compacted.didCompact {
                    accumulator.appendNotice("Context compacted to free tokens.")
                }
            }

            // Track newly emitted native tool calls during this single turn.
            // Use a lock-backed collector: onChunk runs off the MainActor, and the previous
            // `Task { @MainActor in nativeEmittedToolCalls.append }` raced so tool calls were
            // often lost — the model looked "stuck" narrating without ever executing.
            let toolCallCollector = AgentToolCallCollector()
            let thinkingCollector = AgentThinkingBlockCollector()
            accumulator.beginIteration()
            let textBridge = AgentStreamTextBridge()
            let turnTextBefore = accumulator.fullText
            let stopper = AgentStreamStopper()
            let breakLoops = loadedSettings.autoLoopBreakerEnabled
            // The check is not free, and running it on every token made its cost grow with the
            // answer. Every pattern it looks for needs dozens of tokens to form, so sampling the
            // tail periodically catches the same loops far earlier than waiting for the stream to
            // end, which is what used to happen.
            let checkEvery = 24
            let sinceLastCheck = StreamTickCounter()

            // Snapshot before the Task exists. Passing `workingMessages` directly would capture
            // the mutable local rather than evaluating it at the call site, and the loop appends
            // to it further down — safe only because the stream is awaited first, which the
            // compiler cannot see and a later edit could quietly break.
            let messagesForRequest = workingMessages

            do {
                let streamTask = Task<Void, Error> {
                    try await ProviderRouter.shared.stream(
                        provider: provider,
                        model: model,
                        systemPrompt: systemPromptWithTools,
                        messages: messagesForRequest,
                        temperature: agent.temperature,
                        maxTokens: agent.maxTokens,
                        reasoningEffort: effectiveReasoningEffort,
                        tools: availableTools
                    ) { chunk in
                        for tc in chunk.toolCalls {
                            toolCallCollector.add(tc)
                        }
                        for block in chunk.thinkingBlocks {
                            thinkingCollector.add(block)
                        }
                        textBridge.ingest(chunk)
                        let grewText = !chunk.deltaText.isEmpty
                        let grewReasoning = !(chunk.deltaReasoning ?? "").isEmpty
                        if breakLoops, grewText || grewReasoning, sinceLastCheck.tick(every: checkEvery) {
                            if AgentStreamAccumulator.detectsRepetitionLoop(in: textBridge.textTail())
                                || AgentStreamAccumulator.detectsRepetitionLoop(in: textBridge.reasoningTail()) {
                                stopper.stop(reason: "repetition")
                            }
                        }
                        Task { @MainActor in
                            accumulator.applyChunk(chunk)
                        }
                    }
                }
                stopper.attach(streamTask)
                do {
                    try await streamTask.value
                } catch {
                    // Cancelling a stream surfaces differently per transport — `CancellationError`
                    // in-process, `URLError.cancelled` over HTTP. If we asked for the stop, none of
                    // them is a failure, and reporting one would blame the provider for our own
                    // decision. Anything else is a real error and rethrows.
                    guard stopper.stoppedReason != nil else { throw error }
                }
            } catch {
                let snap = textBridge.snapshot()
                accumulator.reconcileFromBridge(
                    text: snap.text,
                    reasoning: snap.reasoning,
                    promptTokens: snap.promptTokens,
                    completionTokens: snap.completionTokens
                )
                accumulator.handleError(error)
                break
            }

            // Flush / recover MainActor UI updates from stream callbacks
            let snap = textBridge.snapshot()
            accumulator.reconcileFromBridge(
                text: snap.text,
                reasoning: snap.reasoning,
                promptTokens: snap.promptTokens,
                completionTokens: snap.completionTokens
            )
            await Task.yield()

            if stopper.stoppedReason != nil || accumulator.isLoopDetected {
                // Say so. A silently truncated repetitive answer looks like the model simply
                // stopped, and the user has no way to know the app cut it off or why.
                accumulator.appendNotice("Stopped: the model was repeating itself.")
                // The repeated text was left as the reply, and nothing said what the turn had
                // done or how to go on: a thirty-minute turn ended on its own looping narration.
                // It moves to Reasoning, and the halt offers Continue from the tool results.
                accumulator.hideTurnNarration(beforeLength: turnTextBefore.count)
                let ran = accumulator.message.toolCalls.count
                accumulator.setHalt(
                    reason: "repetition",
                    text: "The model started repeating itself, so this turn was cut off"
                        + (ran > 0 ? " after \(ran) tool call(s)" : "")
                        + ". Press Continue to resume from where it got to."
                )
                halted = true
                break
            }

            turnPromptTokens += accumulator.message.promptTokens
            turnCompletionTokens += accumulator.message.completionTokens
            if turnPromptTokens + turnCompletionTokens > maxTurnTokens {
                accumulator.setHalt(
                    reason: "token_budget",
                    text: "Turn token budget exceeded (\(turnPromptTokens + turnCompletionTokens) > \(maxTurnTokens)). Press Continue to resume."
                )
                halted = true
                break
            }

            // Inventory questions should be one-shot answers — never enter a tool loop.
            if inventoryPrompt {
                finalStepText = accumulator.stepText(from: turnTextBefore.count)
                finishedNaturally = true
                break
            }

            // Gather tool calls from either native API streaming or Markdown ReAct fallbacks
            var pendingCallsToExecute: [(id: String, tool: String, args: String)] = []
            let nativeEmittedToolCalls = toolCallCollector.snapshot()

            if !nativeEmittedToolCalls.isEmpty {
                for tc in nativeEmittedToolCalls {
                    pendingCallsToExecute.append((id: tc.id, tool: tc.toolName, args: tc.argumentsJson))
                }
            } else {
                let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count))
                let knownMCP = Set((await MCPClientManager.shared.advertisedToolNames()).values.flatMap { $0 })
                var parsedMarkdownCalls = parseToolCalls(from: newlyGeneratedDelta, knownMCP: knownMCP)
                // Fall back to the whole turn only when this step produced no text at all (the
                // accumulator can be reconciled to a shorter string mid-turn). `fullText` keeps the
                // raw call syntax of every earlier step, so parsing it in any other case replayed
                // calls that had already run — an edit applied twice fails "old_string not found",
                // and a replayed file_write overwrites newer content with older.
                if parsedMarkdownCalls.isEmpty,
                   newlyGeneratedDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !accumulator.fullText.isEmpty {
                    parsedMarkdownCalls = parseToolCalls(from: accumulator.fullText, knownMCP: knownMCP)
                        .filter { !textCallsAlreadyRun.contains(Self.callSignature($0.tool, $0.args)) }
                }
                for parsed in parsedMarkdownCalls {
                    textCallsAlreadyRun.insert(Self.callSignature(parsed.tool, parsed.args))
                    pendingCallsToExecute.append((id: UUID().uuidString, tool: parsed.tool, args: parsed.args))
                }
            }

            // If no tool calls were requested from this turn:
            if pendingCallsToExecute.isEmpty {
                let newlyGeneratedDelta = String(accumulator.fullText.dropFirst(turnTextBefore.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowercaseDelta = newlyGeneratedDelta.lowercased()
                if newlyGeneratedDelta.isEmpty && nativeEmittedToolCalls.isEmpty {
                    // Empty model turn — do not silently finalize an blank streaming bubble.
                    if iteration < 2 {
                        accumulator.appendNotice("Model returned no tokens; retrying…")
                        continue
                    }
                    accumulator.setHalt(
                        reason: "empty_response",
                        text: "The model returned an empty response. Press Continue to try again."
                    )
                    halted = true
                    break
                } else {
                    let hasUnfulfilledActionIntent = (
                        lowercaseDelta.contains("let me start") ||
                        lowercaseDelta.contains("let me check") ||
                        lowercaseDelta.contains("let me get") ||
                        lowercaseDelta.contains("let me list") ||
                        lowercaseDelta.contains("let me emit") ||
                        lowercaseDelta.contains("let me search") ||
                        lowercaseDelta.contains("let me proceed") ||
                        lowercaseDelta.contains("let me call") ||
                        lowercaseDelta.contains("i will start by") ||
                        lowercaseDelta.contains("i will now check") ||
                        lowercaseDelta.contains("now let me") ||
                        lowercaseDelta.contains("tools are loaded") ||
                        lowercaseDelta.contains("tool definitions") ||
                        lowercaseDelta.contains("first, let me")
                    ) && newlyGeneratedDelta.count < 1200 && iteration < 6

                    if hasUnfulfilledActionIntent {
                        let toolHint: String = {
                            if let t = availableTools.first(where: { $0.name.contains("call_tool_by_name") }) {
                                return t.name
                            }
                            if let t = availableTools.first(where: { $0.name.contains("get_tool_definitions") }) {
                                return t.name
                            }
                            return availableTools.first(where: { $0.category == .mcp })?.name ?? "mcp_call"
                        }()
                        let nudgeMsg = ChatMessage(
                            sessionId: session.id,
                            role: .user,
                            content: """
                            [System Command]: Stop narrating. Immediately emit a native tool call for `\(toolHint)`, for example:
                            ```tool_call
                            {"tool": "\(toolHint)", "parameters": {}}
                            ```
                            Do not write more prose before the tool call.
                            """
                        )
                        // What it said goes in first, or the nudge answers a message the model
                        // is never shown.
                        workingMessages.append(ChatMessage(
                            sessionId: session.id,
                            role: .assistant,
                            content: accumulator.stepText(from: turnTextBefore.count)
                        ))
                        workingMessages.append(nudgeMsg)
                        continue
                    } else {
                        finalStepText = accumulator.stepText(from: turnTextBefore.count)
                        finishedNaturally = true
                        break
                    }
                }
            }

            // Execute detected tool calls and feed results back into the conversation. The queue
            // used to grow mid-loop, when the mail chaining appended follow-up calls the model had
            // not asked for; that was removed, so what the model emitted is all that runs.
            if !pendingCallsToExecute.isEmpty {
                // The step as the model produced it: its text, then the calls it made. Results
                // follow, each answering its call by id. This used to be appended *after* the
                // results and held the whole turn's text, so the model read its narration out of
                // order and once more per step.
                workingMessages.append(ChatMessage(
                    sessionId: session.id,
                    role: .assistant,
                    content: accumulator.stepText(from: turnTextBefore.count),
                    toolCalls: pendingCallsToExecute.map {
                        ToolCallInfo(
                            id: $0.id,
                            toolName: $0.tool,
                            argumentsJson: Self.sanitizeToolArgumentsJson(toolName: $0.tool, argumentsJson: $0.args)
                        )
                    },
                    // The model's own thinking for this step, verbatim: Claude needs it back with
                    // the tool results or its reasoning starts over each round.
                    thinkingBlocks: thinkingCollector.snapshot()
                ))
                // Hide "Let me check…" preamble once tools are underway.
                accumulator.hideTurnNarration(beforeLength: turnTextBefore.count)
            }
            // Notes for the model that arise while tools run. They wait until every result is in:
            // a message between a call's results breaks the call/result pairing providers require.
            var notesAfterResults: [ChatMessage] = []
            var stopToolLoop = false
            let toolQueue = pendingCallsToExecute
            var queueIndex = 0
            while queueIndex < toolQueue.count {
                let callId = toolQueue[queueIndex].id
                let toolName = toolQueue[queueIndex].tool
                var argsJson = Self.sanitizeToolArgumentsJson(
                    toolName: toolName,
                    argumentsJson: toolQueue[queueIndex].args
                )
                queueIndex += 1

                do {
                    try Task.checkCancellation()
                } catch {
                    accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
                    halted = true
                    stopToolLoop = true
                    break
                }

                var callInfo = ToolCallInfo(
                    id: callId,
                    toolName: toolName,
                    argumentsJson: argsJson,
                    status: .running
                )

                // Sensitive actions (deleting a file, or shell commands under an "always ask"
                // safety policy) are paused for a real user decision before they touch disk.
                if let reason = AgentRunner.approvalReason(
                    toolName: toolName,
                    argumentsJson: argsJson,
                    settings: loadedSettings,
                    sessionId: session.id,
                    workspaceRoot: workspace.folderPath
                ) {
                    callInfo.status = .waitingApproval
                    callInfo.approvalReason = reason
                    accumulator.addToolCall(callInfo)

                    let outcome = await ToolApprovalManager.shared.requestApproval(
                        callId: callId,
                        toolName: toolName,
                        argumentsJson: argsJson,
                        reason: reason
                    )

                    if outcome != .approved {
                        // A person saying no and nobody being there to ask are different events.
                        // Reporting the second as the first would tell the model the user made a
                        // decision they never made.
                        let explanation = outcome == .refusedUnattended
                            ? "This run is unattended, so no one can approve \(reason). Do not retry it; finish what you can without this action and state plainly that it was skipped and why."
                            : "Action rejected by the user (\(reason)). Do not retry this exact call; explain the situation or propose an alternative."
                        callInfo.status = .error
                        callInfo.errorMessage = outcome == .refusedUnattended
                            ? "Skipped: needs approval, and this run is unattended."
                            : "Blocked: the user did not approve this action."
                        accumulator.updateToolCall(callInfo)
                        let toolMsg = ChatMessage(
                            id: callId,
                            sessionId: session.id,
                            role: .tool,
                            content: explanation
                        )
                        workingMessages.append(toolMsg)
                        continue
                    }

                    AgentRunner.rememberApprovedFetch(toolName: toolName, argumentsJson: argsJson, sessionId: session.id)
                    callInfo.status = .running
                    accumulator.updateToolCall(callInfo)
                } else {
                    accumulator.addToolCall(callInfo)
                }

                let signature = Self.callSignature(toolName, argsJson)
                let repeatCount = (identicalToolCounts[signature] ?? 0) + 1
                identicalToolCounts[signature] = repeatCount

                if repeatCount >= 12 {
                    accumulator.setHalt(
                        reason: "stuck_breaker",
                        text: "Identical tool call repeated 12 times (\(toolName)). Press Continue to resume with a new approach."
                    )
                    halted = true
                    stopToolLoop = true
                    break
                }

                var stuckNudge = ""
                if repeatCount >= 8 {
                    stuckNudge = "\n\n[Stuck breaker] Identical call repeated \(repeatCount) times. Stop looping; change strategy or finish."
                } else if repeatCount >= 5 {
                    stuckNudge = "\n\n[Stuck breaker] You've repeated this identical tool call \(repeatCount) times. Try a different approach."
                } else if repeatCount >= 3 {
                    stuckNudge = "\n\n[Stuck breaker] Identical tool+args seen \(repeatCount) times — avoid repeating without progress."
                }

                let startTool = CFAbsoluteTimeGetCurrent()
                var resultOutput: String
                var resultSuccess = true
                var resultError: String?
                var producedImages: [String] = []

                if toolName == "ask_user" {
                    askUserStreak += 1
                    if askUserStreak > 5 {
                        resultSuccess = false
                        resultError = "ask_user streak capped at 5. Stop asking and proceed with best judgment or finish."
                        resultOutput = resultError!
                    } else {
                        let parsed = Self.parseAskUserArgs(argsJson)
                        let answer = await UserChoiceManager.shared.request(
                            question: parsed.question,
                            options: parsed.options,
                            callId: callId
                        )
                        resultOutput = answer
                    }
                } else {
                    askUserStreak = 0

                    if toolName == "exit_plan_mode" {
                        planModeActive = false
                        var settings = PersistenceManager.shared.loadSettings()
                        settings.planModeEnabled = false
                        PersistenceManager.shared.saveSettings(settings)
                        availableTools = PersistenceManager.shared.loadTools().filter(\.isEnabled)
                        _ = ToolSchemaCatalog.ensureParityTools(in: &availableTools)
                        for t in mcpTools {
                            if !availableTools.contains(where: { $0.id == t.id || $0.name == t.name }) {
                                availableTools.append(t)
                            }
                        }
                        accumulator.appendNotice("Plan mode exited.")
                        if let host = EngineHosting.host {
                            var liveSettings = host.settings
                            liveSettings.planModeEnabled = false
                            host.settings = liveSettings
                            host.showToast("Plan mode exited")
                        }
                        resultOutput = "Plan mode exited."
                    } else if planModeActive, ToolCallRepair.isBlockedInPlanMode(toolName) {
                        // The tool list is filtered in plan mode, but a model can still name a tool
                        // it was not offered — and the dispatcher resolves aliases such as `bash`
                        // and `write`. Enforce it here, where the call would actually run.
                        resultSuccess = false
                        resultError = "blocked in plan mode"
                        resultOutput = "Error: plan mode is on, so `\(toolName)` (it changes files or runs commands) was not run. Propose your plan, then call `exit_plan_mode` once the user approves."
                        accumulator.appendNotice("Blocked `\(toolName)` in plan mode.")
                    } else if let note = Self.unchangedReadNote(
                        toolName: toolName, argumentsJson: argsJson, workspaceRoot: workspace.folderPath,
                        log: readLog, transcript: workingMessages
                    ) {
                        resultOutput = note
                        accumulator.appendNotice("Skipped re-reading an unchanged file.")
                    } else if let priorFailures = repeatedFailures[Self.callSignature(toolName, argsJson)],
                              priorFailures >= Self.identicalFailureLimit {
                        // Refuse to run a call that has already failed identically.
                        //
                        // Dead-end detection existed only for MCP (`mcpDeadEnds`), so a
                        // first-party tool could fail the same way forever. Observed: a model
                        // called `screenshot_window` with identical arguments eight times and was
                        // still going when the user stopped it by hand. The model is not being
                        // stupid — nothing told it the attempt was hopeless, and "try again" is a
                        // reasonable thing to do once.
                        resultSuccess = false
                        resultError = "repeated identical call"
                        resultOutput = """
                        Error: this exact call — `\(toolName)` with these exact arguments — has \
                        already failed \(priorFailures) times this turn, with the same result each \
                        time. It was not run again.

                        Nothing has changed that would make it succeed. Either change the \
                        arguments, use a different tool, or tell the user what is blocking you and \
                        stop. Do not call it again unchanged.
                        """
                        accumulator.appendNotice("Blocked a repeated failing call to \(toolName).")
                    } else {
                        let runFrame = AgentRunContext.Frame(provider: provider, model: model, depth: 0, sessionId: session.id)
                        let result = await AgentRunContext.$current.withValue(runFrame) {
                            await ToolExecutionEngine.shared.execute(
                                toolName: toolName,
                                argumentsJson: argsJson,
                                workspace: workspace,
                                currentAgent: agent,
                                callId: callInfo.id
                            )
                        }
                        resultSuccess = result.success
                        resultOutput = Self.describeToolResult(result)
                        resultError = result.error
                        producedImages = result.producedImages
                        callInfo.fileDiff = result.fileDiff
                        callInfo.fileDiffs = result.fileDiffs

                        // `agent_message` builds an `AgentMessage` and hands it back here.
                        // `ToolExecutionResult.createdAgentMessage` had no reader, so every message
                        // the agent sent with that tool was reported as sent and shown nowhere.
                        if let sent = result.createdAgentMessage {
                            onInterAgentMessage(sent)
                        }
                        // Same class of bug, one field over: `agent_spawn` returned the task it ran
                        // and nothing read it, so a real delegation never reached the Sub-Agent
                        // Tree, the message's task cards or the Agent Messages log.
                        if let task = result.createdSubAgentTask {
                            accumulator.upsertSubAgentTask(task)
                            onSubAgentTaskCreated(task)
                            onSubAgentTaskUpdated(task)
                            onInterAgentMessage(AgentMessage(
                                fromAgentId: task.parentAgentId,
                                fromAgentName: task.parentAgentName,
                                toAgentId: task.subAgentId,
                                toAgentName: task.subAgentName,
                                messageType: .taskDelegation,
                                content: task.taskTitle
                            ))
                            onInterAgentMessage(AgentMessage(
                                fromAgentId: task.subAgentId,
                                fromAgentName: task.subAgentName,
                                toAgentId: task.parentAgentId,
                                toAgentName: task.parentAgentName,
                                messageType: .taskResponse,
                                content: task.resultSummary
                            ))
                        }
                        if let todos = result.sessionTodos {
                            onSessionTodosUpdated?(todos)
                        }

                        // Dispatcher servers reject `"arguments":"{}"` (a string). Retry once with
                        // a real map — but only when the nested target is readable. Substituting a
                        // different tool would run something the model never asked for.
                        if !resultSuccess,
                           toolName.lowercased().contains("call_tool_by_name"),
                           let nested = Self.macUseNestedToolName(from: argsJson),
                           (resultOutput + (resultError ?? "")).localizedCaseInsensitiveContains("expected a map")
                            || (resultOutput + (resultError ?? "")).localizedCaseInsensitiveContains("invalid type: string") {
                            let repaired = MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: nested)
                            argsJson = repaired
                            callInfo.argumentsJson = repaired
                            accumulator.updateToolCall(callInfo)
                            accumulator.appendNotice("Retrying `\(nested)` with object `arguments`…")
                            let retry = await AgentRunContext.$current.withValue(runFrame) {
                                await ToolExecutionEngine.shared.execute(
                                    toolName: toolName,
                                    argumentsJson: repaired,
                                    workspace: workspace,
                                    currentAgent: agent,
                                    callId: callInfo.id
                                )
                            }
                            resultSuccess = retry.success
                            resultOutput = Self.describeToolResult(retry)
                            resultError = retry.error
                            producedImages = retry.producedImages
                            callInfo.fileDiff = retry.fileDiff
                            callInfo.fileDiffs = retry.fileDiffs
                        }
                    }
                }

                // Remember real reads only; a skipped one points back at the read it stands for.
                if resultSuccess, Self.canonicalToolName(toolName) == "file_read",
                   !resultOutput.hasPrefix("Unchanged since"),
                   let path = Self.readTarget(argumentsJson: argsJson, workspaceRoot: workspace.folderPath) {
                    readLog[Self.callSignature(toolName, argsJson)] = RecordedRead(
                        callId: callId, modified: Self.modificationDate(path), step: iteration
                    )
                }

                // Track identical failures so the branch above can refuse the third one.
                let repeatKey = Self.callSignature(toolName, argsJson)
                if resultSuccess {
                    repeatedFailures[repeatKey] = 0
                } else if resultError != "repeated identical call" {
                    repeatedFailures[repeatKey, default: 0] += 1
                }

                let bounded = ToolBounds.boundResult(resultOutput + stuckNudge)
                if let notice = bounded.notice {
                    accumulator.appendNotice(notice)
                }

                callInfo.status = resultSuccess ? .success : .error
                callInfo.resultOutput = bounded.text
                callInfo.errorMessage = resultError
                callInfo.durationMs = (CFAbsoluteTimeGetCurrent() - startTool) * 1000
                accumulator.updateToolCall(callInfo)

                if ContextCompactor.isMilestone(
                    toolName: toolName,
                    succeeded: resultSuccess,
                    output: resultOutput
                ) {
                    reachedMilestoneThisIteration = true
                }

                // Track MCP failures that repeating will not fix. A model that keeps re-sending a
                // broken call burns the whole step budget without noticing.
                let isMCPCall = MCPNamespacedTool.isNamespaced(toolName)
                    || toolName == "mcp_call"
                    || toolName == "call_mcp_tool"
                if isMCPCall {
                    let combined = resultOutput + (resultError ?? "")
                    if MCPFailureClassifier.isDeadEnd(combined) {
                        mcpDeadEnds += 1
                    } else {
                        mcpDeadEnds = 0
                    }
                }

                // A meta-tool catalog came back: promote its entries to directly callable tools so
                // the next step is one hop instead of a hand-nested dispatcher call.
                if resultSuccess,
                   MCPCatalogPromote.isCatalogSource(toolName),
                   let parsed = MCPNamespacedTool.parse(toolName),
                   let server = loadedSettings.mcpServers.first(where: { $0.id == parsed.serverId }) {
                    let dispatcher = Self.dispatcherToolName(
                        for: server,
                        among: availableTools,
                        fallbackLeaf: parsed.toolName
                    )
                    let harvested = MCPCatalogPromote.harvest(
                        server: server,
                        executeTool: dispatcher,
                        // Raw, not bounded: the bounded copy is head+tail and no longer parses.
                        resultText: resultOutput
                    ).filter { MCPToolGate.isToolEnabled(server: server, toolName: $0.injectName) }

                    let newcomers = await MCPPromotedToolRegistry.shared.register(harvested)
                    if !newcomers.isEmpty {
                        for promoted in newcomers {
                            let effect = MCPEffectCatalog.classifyNested(
                                server: server,
                                nestedToolName: promoted.injectName
                            )
                            let model = MCPCatalogPromote.toolModel(for: promoted, effect: effect)
                            if !availableTools.contains(where: { $0.name == model.name }) {
                                availableTools.append(model)
                            }
                        }
                        let names = newcomers.prefix(8).map(\.injectName).joined(separator: ", ")
                        let more = newcomers.count > 8 ? " (+\(newcomers.count - 8) more)" : ""
                        accumulator.appendNotice("Promoted \(newcomers.count) \(server.name) tools to direct calls.")
                        notesAfterResults.append(
                            ChatMessage(
                                sessionId: session.id,
                                role: .user,
                                content: """
                                \(newcomers.count) tools on \(server.name) are now directly callable \
                                this turn: \(names)\(more). Call them by their full \
                                `mcp__\(server.id)__<tool>` name with that tool's own arguments — \
                                do not wrap them in \(dispatcher) again.
                                """
                            )
                        )
                    }
                }

                let toolMsg = ChatMessage(
                    id: callId,
                    sessionId: session.id,
                    role: .tool,
                    content: bounded.text,
                    // Images the tool produced ride along on the message, so the provider can
                    // hand them to the model rather than the model reading a path it cannot open.
                    attachments: producedImages.map { path in
                        MessageAttachment(
                            name: (path as NSString).lastPathComponent,
                            path: path,
                            sizeBytes: ImageTransport.fileSize(atPath: path),
                            mimeType: "image/png"
                        )
                    }
                )
                workingMessages.append(toolMsg)
            }

            if stopToolLoop {
                break
            }
            workingMessages.append(contentsOf: notesAfterResults)

            // MCP escalation. Repeating a call that cannot succeed is the most common way a turn
            // burns its whole step budget, so warn once, then take the tools away.
            if !warnedMcpStall, mcpDeadEnds >= 3 {
                warnedMcpStall = true
                workingMessages.append(ChatMessage(
                    sessionId: session.id,
                    role: .user,
                    content: """
                    [System]: MCP calls have failed \(mcpDeadEnds) times in a row. Stop retrying the \
                    same call. Fix the arguments using the recovery hint in the last tool result, \
                    use a different enabled server, use a built-in tool, or answer from what you \
                    already have.
                    """
                ))
            }
            if !mcpDisabledThisTurn, mcpDeadEnds >= 5 {
                mcpDisabledThisTurn = true
                availableTools.removeAll { tool in
                    MCPNamespacedTool.isNamespaced(tool.name)
                        || tool.name == "mcp_call"
                        || tool.name == "call_mcp_tool"
                }
                accumulator.appendNotice("MCP tools disabled for this turn after \(mcpDeadEnds) failures.")
                workingMessages.append(ChatMessage(
                    sessionId: session.id,
                    role: .user,
                    content: """
                    [System]: MCP tools are disabled for the rest of this turn after \(mcpDeadEnds) \
                    consecutive failures. Do not attempt another MCP call. Finish with built-in \
                    tools or tell the user plainly which MCP server failed and what it reported.
                    """
                ))
            }

            // Do not dump raw tool JSON/text into the user-facing chat bubble.
            // The tool observations are already fed back to the LLM in workingMessages as role: .tool / user observation,
            // allowing the LLM to read the result and write a clean, user-friendly natural language response.
        }

        if !halted && !finishedNaturally && iteration >= maxIterations {
            accumulator.setHalt(
                reason: "round_cap",
                text: "Reached the autonomous round cap (\(maxIterations)). Press Continue to keep going from here."
            )
        }

        var modelContext = workingMessages
        if let finalStepText {
            modelContext.append(ChatMessage(
                id: assistantMsgId, sessionId: session.id, role: .assistant, content: finalStepText
            ))
        }
        onModelContextUpdated?(ModelContextSnapshot(
            coveredMessageIds: session.messages.map(\.id) + [assistantMsgId],
            messages: modelContext
        ))

        accumulator.finalize()
    }

    /// The meta-tool on `server` that executes catalog entries by name.
    ///
    /// Servers vary (`call_tool_by_name`, `call_tool`); prefer one that is actually advertised,
    /// and fall back to the tool whose catalog we just read.
    private static func dispatcherToolName(
        for server: MCPServerConfig,
        among tools: [Tool],
        fallbackLeaf: String
    ) -> String {
        let leaves = tools.compactMap { tool -> String? in
            guard let parsed = MCPNamespacedTool.parse(tool.name),
                  parsed.serverId == server.id else { return nil }
            return parsed.toolName
        }
        for candidate in ["call_tool_by_name", "call_tool"] where leaves.contains(candidate) {
            return candidate
        }
        return fallbackLeaf
    }

    /// Whether this agent may decompose the task across sub-agents.
    ///
    /// Both settings gate it and both were previously unread: the global switch must beat a
    /// per-agent "yes" (that is what a global off switch is for), and a zero or negative depth
    /// budget must not read as unlimited.
    /// Who the agent can delegate to, and when it should.
    ///
    /// Without this the model had `agent_spawn` in its tool list and no idea which agents existed,
    /// so it could only guess ids. "Auto-Delegate Complex Tasks" — a toggle nothing read — now
    /// decides whether the agent is encouraged to hand off separable work or only does so when
    /// asked.
    public nonisolated static func teamPromptSection(
        agent: Agent,
        allAgents: [Agent],
        provider: ModelProvider,
        budget: (steps: Int, minutes: Int)? = nil
    ) -> String {
        let team = agent.subAgentIds.compactMap { id in allAgents.first { $0.id == id } }
        let members = team.isEmpty
            ? allAgents.filter { $0.id != agent.id }
            : team
        guard !members.isEmpty else { return "" }
        let lines = members.map { member -> String in
            let about = member.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return "- `\(member.id)` — \(member.name), \(member.role)\(about.isEmpty ? "" : ": \(about)")"
        }
        let when = agent.autoDelegate
            ? """
            Delegate with `agent_spawn` when a sub-task is self-contained and suits a specialist — \
            an independent module to implement, a separate research question, a review of finished \
            work. Give it a precise `task_title` and everything it needs in `task_description`; it \
            cannot ask you questions. Do simple, short or tightly sequential steps yourself.
            """
            : "Only delegate with `agent_spawn` when the user asks for another agent to do something."
        let localCost = provider.type == .local
            ? " This session runs on a local model, so sub-agents run one at a time and each costs a full prompt re-read: delegate sparingly."
            : ""
        // A lead that did not know this handed ten features to one sub-agent with an 8-step,
        // 10-minute budget, twice, and got nothing back either time.
        let limits = budget.map {
            "\nEach sub-agent gets \($0.steps) steps and \($0.minutes) minutes, then is stopped mid-task. "
                + "Delegate one self-contained change per agent_spawn, never a list of features."
                + " Its report is its own account: verify what matters (a file it says it wrote, a claim about the code) before telling the user."
        } ?? ""
        return """

        ### Your team
        \(lines.joined(separator: "\n"))
        \(when)
        A sub-agent runs unattended with its own tools, in an isolated git worktree when the workspace \
        is a repository, and its report comes back as the tool result. Changes it makes stay on its \
        branch until merged; say so rather than claiming they are in the user's checkout.\(localCost)\(limits)
        """
    }

    public static func subAgentSpawningAllowed(agent: Agent, settings: AppSettings) -> Bool {
        agent.canSpawnSubAgents
            && settings.allowSubAgentCreation
            && max(0, settings.maxGlobalSubAgentDepth) > 0
    }

    /// How many times the same call may fail before the loop stops running it.
    ///
    /// Two, because the first retry is reasonable — a transient failure is real — and the third
    /// identical attempt is a loop, not a strategy.
    public static let identicalFailureLimit = 2

    /// Identity of a tool call for repeat detection: the tool and what its arguments mean.
    ///
    /// This compared raw strings, which a model defeats without trying: a real run read the same
    /// script eleven times across two turns by alternating `file_read` and `read_file` and
    /// reordering the keys, so no count ever reached the breaker's first nudge. Aliases of one tool
    /// share a name here, keys are sorted, the path-key spellings `ToolExecutionEngine` accepts
    /// collapse to `path`, and whole-number strings compare equal to the number.
    public nonisolated static func callSignature(_ toolName: String, _ argumentsJson: String) -> String {
        let name = canonicalToolName(toolName)
        let trimmed = argumentsJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return "\(name)\u{1}\(trimmed)"
        }
        var normalized: [String: Any] = [:]
        for (key, value) in dict {
            let canonicalKey = ["filename", "filepath", "file", "file_path"].contains(key) ? "path" : key
            normalized[canonicalKey] = normalizedArgument(value)
        }
        guard JSONSerialization.isValidJSONObject(normalized),
              let out = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8) else {
            return "\(name)\u{1}\(trimmed)"
        }
        return "\(name)\u{1}\(text)"
    }

    private nonisolated static func normalizedArgument(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = ToolExecutionEngine.intArgument(trimmed) { return number }
            return trimmed
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let int = ToolExecutionEngine.intArgument(number.doubleValue) {
            return int
        }
        if let dict = value as? [String: Any] { return dict.mapValues(normalizedArgument) }
        if let list = value as? [Any] { return list.map(normalizedArgument) }
        return value
    }

    /// One name per tool, whichever alias the model used. Mirrors the alias groups
    /// `ToolExecutionEngine` dispatches on; a name not listed is its own canonical name.
    public nonisolated static func canonicalToolName(_ name: String) -> String {
        ToolCallRepair.canonicalName(name)
    }

    /// A file read that succeeded this turn.
    public struct RecordedRead: Sendable, Equatable {
        public var callId: String
        public var modified: Date?
        public var step: Int
    }

    /// A short answer in place of re-reading a file the model already has, or nil to read it.
    ///
    /// The stuck breaker only nudged, and nudges were ignored: one turn read the same 12-line
    /// script six more times after "try a different approach", each copy re-sent and re-read by
    /// the model. When the identical read already succeeded this turn, the file has not changed
    /// since, and that earlier result is still in the transcript unfolded, the contents are
    /// already in front of the model — so say so instead of sending them again.
    public nonisolated static func unchangedReadNote(
        toolName: String,
        argumentsJson: String,
        workspaceRoot: String,
        log: [String: RecordedRead],
        transcript: [ChatMessage]
    ) -> String? {
        guard canonicalToolName(toolName) == "file_read",
              let earlier = log[callSignature(toolName, argumentsJson)],
              let path = readTarget(argumentsJson: argumentsJson, workspaceRoot: workspaceRoot),
              modificationDate(path) == earlier.modified,
              let result = transcript.last(where: { $0.role == .tool && $0.id == earlier.callId }),
              !result.content.hasPrefix("[Earlier tool result compacted]") else { return nil }
        return "Unchanged since you read it at step \(earlier.step) of this turn — the full result of that read is "
            + "above and is still current. Use it instead of reading the file again; to see other lines, "
            + "pass a different offset/limit."
    }

    /// The absolute path a `file_read` call targets.
    public nonisolated static func readTarget(argumentsJson: String, workspaceRoot: String) -> String? {
        guard let data = argumentsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["path", "filename", "filepath", "file", "file_path"] {
            if let raw = dict[key] as? String, !raw.isEmpty {
                let expanded = (raw as NSString).expandingTildeInPath
                return expanded.hasPrefix("/") ? expanded : (workspaceRoot as NSString).appendingPathComponent(expanded)
            }
        }
        return nil
    }

    nonisolated static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Internal rather than private so tests can prove a newly added writing tool is blocked here.
    public static func filterToolsForPlanMode(_ tools: [Tool]) -> [Tool] {
        var filtered = tools.filter { tool in
            if tool.name == "exit_plan_mode" || tool.name == "ask_user" { return true }
            if ToolCallRepair.isBlockedInPlanMode(tool.name) { return false }
            if MCPNamespacedTool.isNamespaced(tool.name) {
                // Plan mode allows reads only, and classification is fail-closed: an MCP tool we
                // cannot positively identify as a read stays out.
                return !tool.requiresApproval
            }
            if tool.name == "mcp_call" || tool.name == "call_mcp_tool" { return false }
            return true
        }
        if !filtered.contains(where: { $0.name == "exit_plan_mode" }) {
            if let exitTool = ToolSchemaCatalog.parityDefaults.first(where: { $0.name == "exit_plan_mode" }) {
                filtered.append(exitTool)
            }
        }
        return filtered
    }

    private static func parseAskUserArgs(_ argsJson: String) -> (question: String, options: [String]) {
        guard let data = argsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("Please choose how to proceed.", [])
        }
        let question = (dict["question"] as? String)
            ?? (dict["prompt"] as? String)
            ?? (dict["message"] as? String)
            ?? "Please choose how to proceed."
        var options: [String] = []
        if let arr = dict["options"] as? [String] {
            options = arr
        } else if let arr = dict["options"] as? [Any] {
            options = arr.compactMap { $0 as? String }
        } else if let choices = dict["choices"] as? [String] {
            options = choices
        }
        return (question, options)
    }

    /// Returns a human-readable reason the call must be interactively approved before it runs,
    /// or nil if it can proceed immediately. Deleting a file is always irreversible enough to ask;
    /// shell commands are gated by the user's configured Terminal Safety Level.
    /// Internal rather than private so tests can prove a newly added writing tool is gated here.
    /// `fetch_url` asks per new site and for every local address; see `WebFetchPolicy`. With web
    /// access off the tool refuses by itself, so there is nothing to ask about.
    static func fetchApprovalReason(argumentsJson: String, settings: AppSettings, sessionId: String) -> String? {
        guard settings.allowWebAccess, settings.askBeforeFetchingNewSites,
              let url = fetchURL(argumentsJson: argumentsJson) else { return nil }
        let previewPorts = Set(DevServerManager.shared.servers.compactMap { $0.url?.port })
        return WebFetchPolicy.approvalReason(
            for: url,
            allowedHosts: WebFetchAllowlist.shared.hosts(for: sessionId),
            previewPorts: previewPorts
        )
    }

    /// Approving a fetch from a public site allows that site for the rest of the chat. Local
    /// addresses are never remembered: they ask every time.
    static func rememberApprovedFetch(toolName: String, argumentsJson: String, sessionId: String) {
        guard ToolCallRepair.builtInCanonical(toolName) == "fetch_url", !sessionId.isEmpty,
              let url = fetchURL(argumentsJson: argumentsJson),
              let host = WebFetchPolicy.normalizedHost(url),
              !WebFetchPolicy.isLocal(host: host) else { return }
        WebFetchAllowlist.shared.allow(host, for: sessionId)
    }

    private static func jsonArguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }

    private static func fetchURL(argumentsJson: String) -> URL? {
        guard let data = argumentsJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (dict["url"] as? String) ?? (dict["href"] as? String) else { return nil }
        return URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func approvalReason(
        toolName: String,
        argumentsJson: String = "{}",
        settings: AppSettings,
        sessionId: String = "",
        workspaceRoot: String = ""
    ) -> String? {
        // Decide on what the call *is*, not on how the model spelled it — and on the arguments the
        // dispatcher will actually use. `delete` and `remove` resolve to file_delete, and `read`
        // with a `file_path` reads that path; a check on the raw name and keys would wave both
        // through unprompted.
        let canonical = ToolCallRepair.builtInCanonical(toolName)
        let toolName = canonical ?? toolName
        var argumentsJson = argumentsJson
        if let canonical, let data = argumentsJson.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let normalizedData = try? JSONSerialization.data(withJSONObject: ToolCallRepair.normalizeArguments(tool: canonical, parsed)),
           let normalized = String(data: normalizedData, encoding: .utf8) {
            argumentsJson = normalized
        }
        switch toolName {
        case "ask_user":
            return nil
        case "file_read", "read_file", "document_extract", "extract_document", "read_pdf_or_image":
            let args = jsonArguments(argumentsJson)
            let path = ["path", "filename", "filepath", "file"].lazy.compactMap { args[$0] as? String }.first ?? ""
            return SensitivePaths.reason(forReading: path, workspaceRoot: workspaceRoot)
        case "grep", "search_code", "code_search":
            let args = jsonArguments(argumentsJson)
            let root = (args["path"] as? String) ?? (args["directory"] as? String) ?? ""
            return SensitivePaths.reason(forSearchingUnder: root, workspaceRoot: workspaceRoot)
        case "fetch_url":
            return fetchApprovalReason(argumentsJson: argumentsJson, settings: settings, sessionId: sessionId)
        case "file_write", "write_file", "create_file", "save_file",
             "edit_file", "file_edit", "multi_edit", "edit_file_multi", "rename_symbol",
             "file_move", "move_file", "mv",
             "file_copy", "copy_file", "cp":
            return "This modifies files on disk."
        case "file_delete", "delete_file", "rm":
            return "This permanently deletes a file from disk."
        case "setup_xcode_language_server":
            return "This writes buildServer.json into the project and may build the scheme with xcodebuild."
        case "revert_changes":
            // Undo is itself destructive: it discards everything the turn produced.
            return "This discards every file change made during this turn."
        case "preview_start":
            return PreviewTools.approvalReason(argumentsJson: argumentsJson)
        case "run_app", "launch_app":
            // `requiresApproval` was set on these in the catalog and read by nothing, so they ran
            // without asking. Launching an arbitrary binary is exactly what should ask.
            return "Launches an app or executable on your Mac."
        case "git_commit":
            return "Commits changes in an agent worktree."
        case "worktree_remove":
            return "Removes an agent worktree and its branch."
        case "terminal_command", "run_command":
            if settings.terminalSafetyLevel == .alwaysAsk {
                return "Runs a shell command on your Mac (Terminal Safety Level: Always Ask Confirmation)."
            }
            // Only where the command is constrained enough for a path check to mean something:
            // under "Unrestricted" any program could read the same file another way.
            if settings.terminalSafetyLevel == .safeOnly {
                let command = (jsonArguments(argumentsJson)["command"] as? String) ?? ""
                return SensitivePaths.reason(forShellCommand: command, workspaceRoot: workspaceRoot)
            }
            return nil
        default:
            // MCP reads auto-run; writes ask. Classification is fail-closed — anything we cannot
            // positively identify as a read on a known server counts as a write.
            if MCPNamespacedTool.isNamespaced(toolName) {
                guard let parsed = MCPNamespacedTool.parse(toolName) else {
                    return "Runs an unidentified Model Context Protocol (MCP) tool."
                }
                let server = settings.mcpServers.first { $0.id == parsed.serverId }
                let leaf = parsed.toolName

                // Meta-tools say nothing about what they do — `call_tool_by_name` is a read when
                // it lists mailboxes and a write when it sends mail. Classify the nested target.
                if leaf == "call_tool_by_name" || leaf == "call_tool" {
                    let nested = macUseNestedToolName(from: argumentsJson)
                    if MCPEffectCatalog.classifyNested(server: server, nestedToolName: nested) == .read {
                        return nil
                    }
                    let label = nested.map { "'\($0)'" } ?? "an unnamed tool"
                    return "Runs \(label) on MCP server '\(server?.name ?? parsed.serverId)', which may change apps or data on this Mac."
                }

                if MCPEffectCatalog.classify(server: server, toolName: leaf, advertised: true) == .read {
                    return nil
                }
                return "Runs '\(leaf)' on MCP server '\(server?.name ?? parsed.serverId)', which may change apps or data on this Mac."
            }
            if toolName == "mcp_call" || toolName == "call_mcp_tool" {
                return "Runs a Model Context Protocol (MCP) tool."
            }
            return nil
        }
    }



    private static func macUseNestedToolName(from argumentsJson: String) -> String? {
        guard let data = argumentsJson.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let name = dict["name"] as? String { return name }
        if let name = dict["tool"] as? String { return name }
        if let name = dict["tool_name"] as? String { return name }
        if let inner = dict["arguments"] as? [String: Any], let name = inner["name"] as? String {
            return name
        }
        return nil
    }

    /// Coerce stringified nested JSON so dispatcher servers receive real objects.
    ///
    /// Repairs the shape of the call the model made; it never substitutes a different tool.
    private static func sanitizeToolArgumentsJson(toolName: String, argumentsJson: String) -> String {
        let leaf = (MCPNamespacedTool.parse(toolName)?.toolName ?? toolName).lowercased()
        guard let data = argumentsJson.data(using: .utf8),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return argumentsJson
        }
        dict = MCPToolArgumentDefaults.normalizeArguments(
            serverName: "macuse",
            toolName: leaf,
            arguments: dict
        )
        if leaf == "call_tool_by_name" || leaf == "call_tool" {
            guard let nested = (dict["name"] as? String) ?? (dict["tool"] as? String) else {
                // No readable target: leave it alone and let the server reject it.
                return argumentsJson
            }
            let inner: [String: Any]
            if let obj = dict["arguments"] as? [String: Any] {
                inner = obj
            } else {
                inner = [:]
            }
            return MCPToolArgumentDefaults.macUseCallArgsJSON(toolName: nested, arguments: inner)
        }
        if leaf == "get_tool_definitions" {
            dict.removeValue(forKey: "arguments")
            if dict["names"] == nil {
                dict["names"] = ["*"]
            }
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let out = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: out, encoding: .utf8) else {
            return argumentsJson
        }
        return s
    }


    /// Tool calls the model wrote as text. See `TextToolCallParser` for what is and isn't accepted.
    private func parseToolCalls(from text: String, knownMCP: Set<String>) -> [(tool: String, args: String)] {
        TextToolCallParser.parse(text) { name in
            let canonical = ToolCallRepair.canonicalName(name)
            return ToolCallRepair.builtInNames.contains(canonical)
                || canonical == "mcp_call"
                || name.hasPrefix("mcp__")
                || knownMCP.contains(name)
        }.map { (tool: $0.tool, args: $0.args) }
    }
}
