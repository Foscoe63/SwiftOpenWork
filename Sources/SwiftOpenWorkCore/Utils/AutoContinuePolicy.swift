import Foundation

/// Whether a turn that just ended should be followed by an automatic "Continue" instead of
/// waiting for the user to send one.
///
/// The ReAct loop only keeps working *within* a turn as long as the model keeps calling tools —
/// the moment a step produces plain text with no tool call, the loop reads that as "the assistant
/// is done" and ends the turn, even mid-task. A small local model narrating "Now let me check
/// TerminalManager..." and then stopping without calling the tool looks, from here, identical to
/// a model that has genuinely finished: both are a turn that ended with no tool call. The signal
/// that tells them apart is the session's own todo list — tracked, still-pending work is the one
/// thing a normal "done, here's the answer" reply and a stalled one don't have in common.
public enum AutoContinuePolicy {

    /// The exact text sent for both a manual Continue-button press and an automatic one, so a
    /// resumed turn cannot tell the two apart and the model gets the same instruction either way.
    public static let continuePrompt = "Continue from where you stopped. Do not repeat completed work."

    /// The continue prompt, addressed to `agentSlug` in a group chat. Sent bare, a group would
    /// treat it as a message to the whole room and every agent would answer it.
    public static func continuePrompt(addressedTo agentSlug: String?) -> String {
        guard let agentSlug, !agentSlug.isEmpty else { return continuePrompt }
        return "@\(agentSlug) \(continuePrompt)"
    }

    /// Whether `text` is the continue prompt, bare or addressed to one agent.
    public static func isContinuePrompt(_ text: String) -> Bool {
        text == continuePrompt || (text.hasPrefix("@") && text.hasSuffix(" " + continuePrompt))
    }

    /// `haltReason` is `ChatMessage.haltReason` on the turn's final assistant message: `"stopped"`
    /// when the user pressed Stop, `"round_cap"` when the autonomous round budget ran out, or nil
    /// when the turn ended on its own. `finalText` is that message's content. `pendingTodos` is
    /// whether the session's todo list has any item not marked done.
    public static func shouldAutoContinue(
        haltReason: String?,
        finalText: String,
        pendingTodos: Bool
    ) -> Bool {
        // An explicit Stop is the user taking the wheel; resuming it automatically would make
        // Stop feel ignored.
        if haltReason == "stopped" { return false }
        // Ran out of budget mid-task, unambiguously not finished, regardless of todos — this is
        // exactly what the manual Continue button is already for.
        if haltReason == "round_cap" { return true }
        // Any other halt reason is one this policy does not yet recognise; a turn that halted for
        // a reason we cannot read is not something to resume blindly.
        guard haltReason == nil else { return false }
        // A natural end with nothing left tracked as pending is an ordinary finished reply —
        // "hello" / "Hi! How can I help?" must not loop forever just because it made no tool call.
        guard pendingTodos else { return false }
        return !endsWithQuestion(finalText)
    }

    /// A conservative check for "the assistant is asking the user something," so auto-continue
    /// never talks over a real question — only the last non-empty line counts, so a question
    /// asked earlier in a status update (about the *code*, not the reader) does not count.
    public static func endsWithQuestion(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return false }
        return last.hasSuffix("?")
    }

    /// Phrases that announce a tool call the model is about to make.
    static let intentPhrases = [
        "let me start", "let me check", "let me get", "let me list", "let me emit", "let me search",
        "let me proceed", "let me call", "let me look", "let me read", "let me run", "let me open",
        "i will start by", "i will now check", "i'll start by", "now let me", "first, let me",
        "tools are loaded", "tool definitions",
        // The verbs a coding turn actually stalls on. Qwen3-Coder-Next ended turns on "Let me
        // remove the duplicate loop (lines 108-139) to fix this properly." and on "Now let me
        // build the project to verify the fix.", and the user had to type "continue" each time.
        "let me fix", "let me build", "let me rebuild", "let me remove", "let me update",
        "let me add", "let me edit", "let me apply", "let me verify", "let me find", "let me create",
        "let me write", "let me try", "let me also", "let me now", "let me first", "let me see",
        "let me examine", "let me inspect", "let me test", "let me implement", "let me make",
        "let me replace", "let me delete", "let me clean", "let me re-read", "let me continue",
        "i'll now", "i will now", "next, i'll", "next, i will",
    ]

    /// Whether a step's text *ends* by announcing an action it never took ("Now let me check the
    /// logs:"), which is a stall worth nudging. Only the last sentence counts, so a finished answer
    /// that says "now let me explain" early on, or closes with "let me know if…", is not a stall.
    public static func endsWithUnfulfilledIntent(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last?.lowercased() else { return false }
        if lastLine.hasSuffix("?") { return false }
        // The last sentence of the last line.
        let body = lastLine.trimmingCharacters(in: CharacterSet(charactersIn: ".!:…").union(.whitespaces))
        var lastSentence = Substring(body)
        for boundary in [". ", "! ", "? "] {
            if let range = lastSentence.range(of: boundary, options: .backwards) {
                lastSentence = lastSentence[range.upperBound...]
            }
        }
        if lastSentence.contains("let me know") { return false }
        return intentPhrases.contains { lastSentence.contains($0) }
    }
}
