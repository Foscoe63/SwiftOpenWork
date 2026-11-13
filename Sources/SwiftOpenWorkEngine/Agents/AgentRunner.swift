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
        // Code lines are left out: a model drafting an edit quotes the same snippet as "from" and
        // "to", which reads as consecutive identical lines. A contiguous code spiral is still
        // caught by check 1.
        let rawLines = text.components(separatedBy: .newlines)
            .filter { !Self.looksLikeCode($0) }
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

        // 4. Repeated N-gram phrases in trailing window: an identical 12-word sequence 4+ times.
        //
        // This was 5 words, then 8 words three times. Both flag ordinary work. A model planning a
        // batch of reads lists the same files three times ("read the AI service, learning manager,
        // scheduled cleanup manager, notification service…"), and one drafting an edit quotes the
        // same snippet in its "from" and "to" forms. Two real turns were cut off mid-plan that way,
        // and the retry replanned from scratch and tripped it again. A true spiral is also caught
        // by checks 1 and 2, so this one only needs to catch long phrases that keep coming back.
        // Code lines are left out: identifiers and call syntax repeat legitimately.
        let prose = text.suffix(1500)
            .components(separatedBy: .newlines)
            .filter { !Self.looksLikeCode($0) }
            .joined(separator: " ")
        let words = prose.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let gramLength = 12
        if words.count >= 30 {
            var ngrams: [String: Int] = [:]
            for i in 0..<(words.count - gramLength + 1) {
                let gram = words[i..<(i + gramLength)].joined(separator: " ")
                let currentCount = (ngrams[gram] ?? 0) + 1
                ngrams[gram] = currentCount
                if currentCount >= 4 {
                    return true
                }
            }
        }

        return false
    }

    /// A line that is source code rather than prose: indented, or carrying call/brace syntax.
    nonisolated static func looksLikeCode(_ line: String) -> Bool {
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return true }
        let syntax: Set<Character> = ["{", "}", ";", "(", ")", "=", "<", ">", "[", "]"]
        return line.filter { syntax.contains($0) }.count >= 2
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

    /// The turn's running totals across every model call so far, for the composer's Sent / Recv.
    public func setBilled(prompt: Int, completion: Int, lastPrompt: Int? = nil) {
        // The last call's prompt is what the composer's Prompt shows once the box is empty. A
        // provider that reports nothing left it at zero, so it takes the estimate.
        // The caller has already reconciled the provider's figure with the request's own size, so
        // it wins over whatever the stream reported.
        if let lastPrompt { message.promptTokens = lastPrompt }
        message.billedPromptTokens = prompt
        message.billedCompletionTokens = completion
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

        // Remove TOOL_CALL = { ... } — to the *matching* brace, so a call with an object-valued
        // argument does not leave its tail behind.
        cleaned = removeToolCallAssignments(from: cleaned)

        // Remove ```tool_call ... ``` or ```json fences that hold a tool call. A fence is removed
        // only when what is inside really is one: this matched any block whose first key was
        // "name", so an answer showing a `package.json` lost it — and the loss was fed back to
        // the model as its own history.
        let codeBlockPattern = "```(?:tool_call|json)?\\s*(?:\\r?\\n)?\\s*\\{\\s*\"(?:tool|name|mcp|server)\"[\\s\\S]*?\\}\\s*(?:\\r?\\n)?```"
        cleaned = removeMatches(of: codeBlockPattern, in: cleaned) { looksLikeToolCall($0) }

        // Remove XML tool calls <tool_call>...</tool_call>
        let xmlPattern = "<tool_call>[\\s\\S]*?(?:</tool_call>|$)"
        if let regex = try? NSRegularExpression(pattern: xmlPattern, options: []) {
            let range = NSRange(location: 0, length: (cleaned as NSString).length)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Remove raw naked tool JSON if it was the entirety or beginning of a line — again only
        // when it is a tool call rather than data that happens to start with `"name"`.
        let nakedPattern = "(?m)^\\s*\\{\\s*\"(?:tool|name|mcp|server)\"\\s*:[\\s\\S]*?\\}\\s*$"
        cleaned = removeMatches(of: nakedPattern, in: cleaned) { looksLikeToolCall($0) }

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

    /// Whether `text` — a fenced block or a bare object — is a tool call the model wrote as text.
    ///
    /// A tool call names a tool and (except for `{"tool": "x"}`) carries arguments. Data that
    /// merely has a `name` — a manifest, a config, an API response — does not.
    static func looksLikeToolCall(_ text: String) -> Bool {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return false }
        let body = String(text[open...close])
        guard let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Not valid JSON (single quotes, a trailing comma): decide on the words in it.
            return body.contains("\"parameters\"") || body.contains("\"arguments\"") || body.contains("\"tool\"")
        }
        let argumentKeys = ["parameters", "arguments", "args", "input"]
        let hasArguments = argumentKeys.contains { object[$0] != nil }
        if object["tool"] is String { return true }
        if let function = object["function"] as? [String: Any], function["name"] is String { return true }
        if object["mcp"] is String { return true }
        if object["server"] is String, object["action"] != nil { return true }
        if object["name"] is String, hasArguments { return true }
        return false
    }

    /// Removes each regex match for which `shouldRemove(matchedText)` holds.
    private static func removeMatches(of pattern: String, in text: String, where shouldRemove: (String) -> Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let ns = text as NSString
        var result = text
        // Back to front, so earlier ranges stay valid as later ones are removed.
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).reversed() {
            guard shouldRemove(ns.substring(with: match.range)),
                  let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
        }
        return result
    }

    /// `TOOL_CALL = {…}` up to the brace that closes it (string-aware).
    private static func removeToolCallAssignments(from text: String) -> String {
        var result = text
        var search = result.startIndex
        while let anchor = result.range(of: "TOOL_CALL", range: search..<result.endIndex) {
            var cursor = anchor.upperBound
            while cursor < result.endIndex, result[cursor] == "=" || result[cursor].isWhitespace { cursor = result.index(after: cursor) }
            guard cursor < result.endIndex, result[cursor] == "{", let end = closingBrace(in: result, from: cursor) else {
                search = anchor.upperBound
                continue
            }
            result.removeSubrange(anchor.lowerBound...end)
            search = min(anchor.lowerBound, result.endIndex)
        }
        return result
    }

    private static func closingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
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
final class AgentStreamTextBridge: @unchecked Sendable {
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
final class AgentStreamStopper: @unchecked Sendable {
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
        agent baseAgent: Agent,
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
        onModelContextUpdated: ((ModelContextSnapshot) -> Void)? = nil,
        group: GroupChat.Turn? = nil
    ) async {
        // An agent that is another program (Claude Code, Codex, Gemini CLI…) runs over ACP; the
        // model, provider and tool loop below are its own business.
        if let external = baseAgent.externalAgent {
            await ACPAgentRunner.run(
                session: session, agent: baseAgent, config: external, workspace: workspace,
                onMessageUpdated: onMessageUpdated, onSessionTodosUpdated: onSessionTodosUpdated
            )
            return
        }
        await AgentTurn(
            session: session, agent: baseAgent, provider: provider, model: model, workspace: workspace,
            allAgents: allAgents, reasoningOverride: reasoningOverride,
            onMessageUpdated: onMessageUpdated, onSubAgentTaskCreated: onSubAgentTaskCreated,
            onSubAgentTaskUpdated: onSubAgentTaskUpdated, onInterAgentMessage: onInterAgentMessage,
            onSessionTodosUpdated: onSessionTodosUpdated, onModelContextUpdated: onModelContextUpdated,
            group: group
        ).run()
    }

    /// `workingMessages` without the "[System Command]" and "[System]:" notes the loop adds to
    /// steer a turn (stop narrating, stop retrying a dead MCP server).
    static func droppingHarnessNudges(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { message in
            !(message.role == .user
                && (message.content.hasPrefix("[System Command]") || message.content.hasPrefix("[System]:")))
        }
    }

    /// The meta-tool on `server` that executes catalog entries by name.
    ///
    /// Servers vary (`call_tool_by_name`, `call_tool`); prefer one that is actually advertised,
    /// and fall back to the tool whose catalog we just read.
    static func dispatcherToolName(
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
            : " Several agent_spawn calls in one step run at the same time (up to \(maxParallelSubAgents)), each in its own worktree: "
                + "put independent sub-tasks in the same step, and give each the files it owns so they do not overlap."
        let messaging = agent.canCommunicateWithOthers
            ? " A running sub-agent can be sent a message with agent_message; it reads it at its next step."
            : ""
        // A lead that did not know this handed ten features to one sub-agent with an 8-step,
        // 10-minute budget, twice, and got nothing back either time.
        let limits = budget.map {
            "\nEach sub-agent gets \($0.steps) steps and \($0.minutes) minutes, then is stopped mid-task; "
                + "for a bigger piece pass max_steps (up to \(min(SubAgentExecutor.maxRequestableSteps, $0.steps * 3))). "
                + "Delegate one self-contained change per agent_spawn, never a list of features."
                + " Its report is its own account: verify what matters (a file it says it wrote, a claim about the code) before telling the user."
        } ?? ""
        return """

        ### Your team
        \(lines.joined(separator: "\n"))
        \(when)
        A sub-agent runs unattended with its own tools, in an isolated git worktree when the workspace \
        is a repository, and its report comes back as the tool result. Changes it makes stay on its \
        branch until merged; say so rather than claiming they are in the user's checkout, and bring \
        them in with worktree_merge when the user wants them.\(messaging)\(localCost)\(limits)
        """
    }

    public static func subAgentSpawningAllowed(agent: Agent, settings: AppSettings) -> Bool {
        agent.canSpawnSubAgents
            && settings.allowSubAgentCreation
            && max(0, settings.maxGlobalSubAgentDepth) > 0
    }

    /// Tools whose success changes the workspace, and so makes an earlier identical call new again.
    /// Built-in tools that only read: no file, process or network effect, and no dependence on the
    /// order they run in. A model that asks for five `file_read`s in one step gets them concurrently
    /// instead of one after another. Conservative on purpose — anything not listed runs in order.
    public nonisolated static func isParallelSafe(_ toolName: String) -> Bool {
        guard let canonical = ToolCallRepair.builtInCanonical(toolName) else { return false }
        switch canonical {
        case "file_read", "file_list", "glob", "grep", "find_symbol", "workspace_semantic_search",
             "git_status", "git_diff", "git_log", "changed_files", "get_current_date", "calculator":
            return true
        default:
            return false
        }
    }

    /// Sub-agents started together at most. Each holds a model stream and its own worktree.
    public nonisolated static let maxParallelSubAgents = 4

    /// Whether a step's `agent_spawn` calls start together rather than one after another: there
    /// must be more than one, and the run must not be on the local engine, which serialises
    /// generation anyway.
    public nonisolated static func spawnsRunTogether(_ toolNames: [String], provider: ModelProvider) -> Bool {
        guard provider.type != .local else { return false }
        return toolNames.filter { canonicalToolName($0) == "agent_spawn" }.count > 1
    }

    public nonisolated static func changesFiles(_ toolName: String) -> Bool {
        switch canonicalToolName(toolName) {
        case "file_write", "edit_file", "multi_edit", "file_delete", "file_move", "file_copy",
             "rename_symbol", "revert_changes", "git_commit", "worktree_merge":
            return true
        default:
            return false
        }
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
        let when = earlier.step < 0 ? "earlier in this conversation" : "at step \(earlier.step) of this turn"
        return "Unchanged since you read it \(when) — the full result of that read is "
            + "above and is still current. Use it instead of reading the file again; to see other lines, "
            + "pass a different offset/limit."
    }

    /// Reads from earlier turns whose full result is still in `transcript` and whose file has not
    /// been modified since, so a resumed turn does not read them again. `step` is -1 for these.
    public nonisolated static func seedReadLog(
        transcript: [ChatMessage],
        workspaceRoot: String
    ) -> [String: RecordedRead] {
        var results: [String: ChatMessage] = [:]
        for m in transcript where m.role == .tool { results[m.id] = m }
        var log: [String: RecordedRead] = [:]
        for m in transcript where m.role == .assistant {
            for call in m.toolCalls where canonicalToolName(call.toolName) == "file_read" {
                guard let result = results[call.id],
                      !result.content.hasPrefix("[Earlier tool result compacted]"),
                      !result.content.hasPrefix("Unchanged since"),
                      !result.content.hasPrefix("Error"),
                      let path = readTarget(argumentsJson: call.argumentsJson, workspaceRoot: workspaceRoot),
                      let modified = modificationDate(path),
                      modified <= call.timestamp else { continue }
                log[callSignature(call.toolName, call.argumentsJson)] = RecordedRead(
                    callId: call.id, modified: modified, step: -1)
            }
        }
        return log
    }

    /// The absolute path a `file_read` call targets.
    /// (tool, path) identity for missing-path failure counting; nil when the call names no path.
    nonisolated static func missingPathKey(_ toolName: String, _ argumentsJson: String, workspaceRoot: String) -> String? {
        guard let path = readTarget(argumentsJson: argumentsJson, workspaceRoot: workspaceRoot) else { return nil }
        let name = canonicalToolName(toolName)
        // `grep` on a missing file and `file_read` of it are the same dead end.
        return (name == "grep" ? "read" : name) + "\u{1}" + path
    }

    nonisolated static func isMissingPathFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("no such file") || lower.contains("does not exist")
            || lower.contains("no matches for") && lower.contains("in 0 files")
    }

    /// The "Did you mean: ..." sentence from a not-found error, or a `glob` nudge when it had none.
    nonisolated static func didYouMeanHint(in text: String) -> String {
        if let range = text.range(of: "Did you mean:") {
            let tail = text[range.lowerBound...]
            let sentence = tail.prefix(while: { $0 != "\n" })
            return String(sentence)
        }
        return "Use `glob` to find the right path rather than guessing."
    }

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

    static func parseAskUserArgs(_ argsJson: String) -> (question: String, options: [String]) {
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
        var reason = baseApprovalReason(
            toolName: toolName, argumentsJson: argumentsJson, settings: settings,
            sessionId: sessionId, workspaceRoot: workspaceRoot
        )
        let canonical = ToolCallRepair.builtInCanonical(toolName) ?? toolName
        // Standing rules (`.swiftopenwork/permissions.json`) decide individual calls on top of the
        // approval level. A deny is enforced separately, before this is asked; here an allow
        // silences a prompt and an ask adds one. The guards that are not about trusting the agent
        // never yield to an allow.
        let neverAllowed: Set<String> = [
            "exit_plan_mode", "fetch_url",
            "file_read", "read_file", "document_extract", "extract_document", "read_pdf_or_image",
            "grep", "search_code", "code_search",
        ]
        if let verdict = PermissionRules.verdict(toolName: toolName, argumentsJson: argumentsJson, workspaceRoot: workspaceRoot) {
            switch verdict.action {
            case .allow where !neverAllowed.contains(canonical):
                reason = nil
            case .ask:
                // An explicit rule outranks "Allow All": the person wrote it to be asked.
                return reason ?? verdict.explanation
            default:
                break
            }
        }
        // "Allow All" in the composer means the agent is not interrupted: file edits, deletes, MCP
        // writes, app launches and commits stop asking too. What stays is a guard that is not
        // about trusting the agent: leaving plan mode, secret files, and the fetch-site policy
        // (which has its own setting).
        guard reason != nil, settings.terminalSafetyLevel == .allowEverything else { return reason }
        return neverAllowed.contains(canonical) ? reason : nil
    }

    private static func baseApprovalReason(
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
        case "exit_plan_mode":
            // Plan mode is the user's guard against the agent changing things before they have
            // seen a plan. The instructions say to exit "after approval", but nothing checked, so
            // the model could lift the guard itself and persist that to settings.
            return settings.planModeEnabled
                ? "Ends plan mode, after which the agent may change files and run commands."
                : nil
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
             "file_copy", "copy_file", "cp", "document_create":
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
        case "pr_create":
            return "Pushes the current branch to origin and opens a pull request on GitHub."
        case "worktree_remove":
            return "Removes an agent worktree and its branch."
        case "worktree_merge":
            return "Brings an agent branch's changes into your checkout."
        case "send_input":
            // Typed text goes to a program that may be a shell or a REPL, so it asks wherever the
            // command itself would have, and under the read-only level too.
            if settings.terminalSafetyLevel != .allowAll, settings.terminalSafetyLevel != .allowEverything {
                return "Types input into a command running in the terminal."
            }
            return nil
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
                return mcpApprovalReason(
                    server: server, serverLabel: server?.name ?? parsed.serverId,
                    leaf: parsed.toolName, argumentsJson: argumentsJson
                )
            }
            if toolName == "mcp_call" || toolName == "call_mcp_tool" {
                return "Runs a Model Context Protocol (MCP) tool."
            }
            // A bare or dotted MCP name (`send_message`, `github.create_issue`). The executor
            // resolves these to a server and runs them, so the approval check has to resolve them
            // the same way — it used to look only at `mcp__`-prefixed names, and a write tool
            // called without the prefix ran with no prompt.
            // Built-ins are handled above; one that reaches here only shares a name with an MCP
            // tool, and the executor runs the built-in.
            guard canonical == nil else { return nil }
            let enabled = settings.mcpServers.filter(\.isEnabled)
            guard !enabled.isEmpty else { return nil }
            let advertised = MCPAdvertisedSnapshot.current
            let dotted = toolName.components(separatedBy: ".")
            if dotted.count == 2, !dotted[0].isEmpty, !dotted[1].isEmpty {
                if case .resolved(let server) = MCPToolRouting.resolveServer(
                    requested: dotted[0], toolName: dotted[1], enabled: enabled, advertised: advertised
                ) {
                    return mcpApprovalReason(
                        server: server, serverLabel: server.name, leaf: dotted[1], argumentsJson: argumentsJson
                    )
                }
                return nil
            }
            if let owned = MCPToolRouting.serverOwning(tool: toolName, servers: enabled, advertised: advertised) {
                return mcpApprovalReason(
                    server: owned.server, serverLabel: owned.server.name, leaf: owned.tool, argumentsJson: argumentsJson
                )
            }
            return nil
        }
    }

    /// Whether an MCP call needs a person, judged on the tool it will actually run.
    /// Whether plan mode must refuse this MCP call: it is not positively identified as a read.
    /// Classification is fail-closed, the same as for approvals, but does not depend on them.
    static func planModeRefusesMCP(toolName: String, argumentsJson: String, settings: AppSettings) async -> Bool {
        if let promoted = await MCPPromotedToolRegistry.shared.lookup(toolName) {
            let server = settings.mcpServers.first { $0.id == promoted.serverId }
            return MCPEffectCatalog.classifyNested(server: server, nestedToolName: promoted.injectName) != .read
        }
        guard let parsed = MCPNamespacedTool.parse(toolName) else { return false }
        let server = settings.mcpServers.first { $0.id == parsed.serverId }
        return mcpApprovalReason(
            server: server, serverLabel: server?.name ?? parsed.serverId,
            leaf: parsed.toolName, argumentsJson: argumentsJson
        ) != nil
    }

    private static func mcpApprovalReason(
        server: MCPServerConfig?, serverLabel: String, leaf: String, argumentsJson: String
    ) -> String? {
        // Meta-tools say nothing about what they do — `call_tool_by_name` is a read when
        // it lists mailboxes and a write when it sends mail. Classify the nested target.
        if leaf == "call_tool_by_name" || leaf == "call_tool" {
            let nested = macUseNestedToolName(from: argumentsJson)
            if MCPEffectCatalog.classifyNested(server: server, nestedToolName: nested) == .read {
                return nil
            }
            let label = nested.map { "'\($0)'" } ?? "an unnamed tool"
            return "Runs \(label) on MCP server '\(serverLabel)', which may change apps or data on this Mac."
        }
        if MCPEffectCatalog.classify(server: server, toolName: leaf, advertised: true) == .read {
            return nil
        }
        return "Runs '\(leaf)' on MCP server '\(serverLabel)', which may change apps or data on this Mac."
    }

    static func macUseNestedToolName(from argumentsJson: String) -> String? {
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
    static func sanitizeToolArgumentsJson(toolName: String, argumentsJson: String) -> String {
        let leaf = (MCPNamespacedTool.parse(toolName)?.toolName ?? toolName).lowercased()
        // Only the dispatcher shapes have anything to repair here. Every other tool — built-in or
        // a server's own — keeps its arguments exactly as sent: this used to parse any string
        // starting with `{` or `[` into an object for *every* tool, so `file_write` of a JSON
        // file arrived as an object and was re-serialised with sorted keys. A server's own tools
        // are repaired at dispatch, where the schema says which parameters are structured.
        let dispatcherShape = leaf == "call_tool_by_name" || leaf == "call_tool"
            || leaf == "get_tool_definitions" || leaf == "mcp_call" || leaf == "call_mcp_tool"
        guard dispatcherShape else { return argumentsJson }
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
    func parseToolCalls(from text: String, knownMCP: Set<String>) -> [(tool: String, args: String)] {
        TextToolCallParser.parse(text) { name in
            let canonical = ToolCallRepair.canonicalName(name)
            return ToolCallRepair.builtInNames.contains(canonical)
                || canonical == "mcp_call"
                || name.hasPrefix("mcp__")
                || knownMCP.contains(name)
        }.map { (tool: $0.tool, args: $0.args) }
    }
}
