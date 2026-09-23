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
}
