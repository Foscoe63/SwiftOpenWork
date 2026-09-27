import Foundation

// A loop: one goal, several steps, and a check on each.
//
// Ported from Radiant's Loop (server/loop-rules.js). A task is done when the model stops talking,
// which is not the same as done. A loop step is done when a condition the user wrote is met, and
// a step that fails goes round again carrying the reason it failed.

public enum LoopStepState: String, Codable, CaseIterable, Sendable {
    case pending, working, checking, passed, failed

    public var label: String {
        switch self {
        case .pending: return "Waiting"
        case .working: return "Working"
        case .checking: return "Checking"
        case .passed: return "Passed"
        case .failed: return "Failed"
        }
    }
}

public enum LoopRunState: String, Codable, CaseIterable, Sendable {
    case idle, running, failed, done

    public var label: String {
        switch self {
        case .idle: return "Not running"
        case .running: return "Running"
        case .failed: return "Stopped"
        case .done: return "Finished"
        }
    }
}

public struct LoopStep: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Anything else the agent should know about this step.
    public var prompt: String
    /// A sentence describing what "done" looks like. Judged by an agent in a separate turn.
    public var check: String
    /// A shell command that has to exit 0. Runs first, costs nothing, cannot be argued with.
    public var checkCommand: String
    public var agentId: String?
    /// A second agent to grade the first. Without one the same agent marks its own homework.
    public var checkAgentId: String?
    public var maxAttempts: Int
    public var state: LoopStepState
    public var attempts: Int
    public var sessionId: String?
    public var checkSessionId: String?
    public var lastFail: String?

    public init(
        id: String = "step-" + String(UUID().uuidString.prefix(6)).lowercased(),
        title: String = "",
        prompt: String = "",
        check: String = "",
        checkCommand: String = "",
        agentId: String? = nil,
        checkAgentId: String? = nil,
        maxAttempts: Int = LoopRules.defaultAttempts,
        state: LoopStepState = .pending,
        attempts: Int = 0,
        sessionId: String? = nil,
        checkSessionId: String? = nil,
        lastFail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.check = check
        self.checkCommand = checkCommand
        self.agentId = agentId
        self.checkAgentId = checkAgentId
        self.maxAttempts = maxAttempts
        self.state = state
        self.attempts = attempts
        self.sessionId = sessionId
        self.checkSessionId = checkSessionId
        self.lastFail = lastFail
    }

    /// Does anything at all verify this step?
    public var isChecked: Bool {
        !check.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !checkCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct AgentLoop: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var title: String
    public var detail: String
    /// Folder the steps and check commands run in. Empty means the workspace folder.
    public var cwd: String
    public var steps: [LoopStep]
    public var currentStep: Int
    public var state: LoopRunState
    /// A sentence describing what the whole loop achieved. Judged once at the end of a pass.
    public var goalCheck: String
    public var goalCommand: String
    public var maxPasses: Int
    public var pass: Int
    public var lastGoalFail: String?
    public var goalSessionId: String?
    /// Minutes between self-started runs. Nil means only when the user presses Run.
    public var everyMinutes: Int?
    public var consecutiveFailures: Int
    public var scheduleOffReason: String?
    public var scheduledAt: Date?
    public var lastRunAt: Date?
    public var lastOutcome: String?
    public var createdAt: Date

    public init(
        id: String = "loop-" + String(UUID().uuidString.prefix(8)).lowercased(),
        workspaceId: String = "default-workspace",
        title: String,
        detail: String = "",
        cwd: String = "",
        steps: [LoopStep] = [],
        currentStep: Int = 0,
        state: LoopRunState = .idle,
        goalCheck: String = "",
        goalCommand: String = "",
        maxPasses: Int = LoopRules.defaultPasses,
        pass: Int = 1,
        lastGoalFail: String? = nil,
        goalSessionId: String? = nil,
        everyMinutes: Int? = nil,
        consecutiveFailures: Int = 0,
        scheduleOffReason: String? = nil,
        scheduledAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastOutcome: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.detail = detail
        self.cwd = cwd
        self.steps = steps
        self.currentStep = currentStep
        self.state = state
        self.goalCheck = goalCheck
        self.goalCommand = goalCommand
        self.maxPasses = maxPasses
        self.pass = pass
        self.lastGoalFail = lastGoalFail
        self.goalSessionId = goalSessionId
        self.everyMinutes = everyMinutes
        self.consecutiveFailures = consecutiveFailures
        self.scheduleOffReason = scheduleOffReason
        self.scheduledAt = scheduledAt
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.createdAt = createdAt
    }

    public var hasGoalCheck: Bool {
        !goalCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !goalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stopped with every step green: the goal check, not a step, said no.
    public var failedOnGoal: Bool {
        state == .failed && !steps.contains { $0.state == .failed }
    }
}

/// What a loop decides, separated from where it stores things. Pure on purpose: the verdict reader
/// is the only thing between "the model said some words" and "this step is finished", and the
/// retry prompt is the only thing that makes a second attempt differ from the first. Both need a
/// string to test, not a model.
public enum LoopRules {

    // An unbounded retry is an unbounded bill. Three is enough for the ordinary miss and stops a
    // step that cannot pass from spending the night proving it.
    public static let defaultAttempts = 3
    public static let maxAttempts = 10
    public static let defaultPasses = 1
    public static let maxPasses = 10
    public static let minEveryMinutes = 1
    public static let maxEveryMinutes = 60 * 24 * 7
    /// Two failed runs in a row switch a schedule off rather than repeating the failure forever.
    public static let scheduleGiveUp = 2
    /// How much of a failing command's output travels into the retry. The tail, not the head: a
    /// test runner prints its banner first and its summary last.
    public static let evidenceChars = 800

    public static func clampAttempts(_ n: Int) -> Int { min(maxAttempts, max(1, n)) }
    public static func clampPasses(_ n: Int) -> Int { min(maxPasses, max(1, n)) }
    public static func clampEvery(_ n: Int) -> Int { min(maxEveryMinutes, max(minEveryMinutes, n)) }

    /// Trim the text fields and clamp the numbers. Steps without a title are dropped.
    public static func normalized(_ loop: AgentLoop) -> AgentLoop {
        var l = loop
        l.title = loop.title.trimmingCharacters(in: .whitespacesAndNewlines)
        l.detail = loop.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        l.cwd = loop.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        l.goalCheck = loop.goalCheck.trimmingCharacters(in: .whitespacesAndNewlines)
        l.goalCommand = loop.goalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        l.maxPasses = clampPasses(loop.maxPasses)
        l.everyMinutes = loop.everyMinutes.map(clampEvery)
        l.steps = loop.steps.compactMap { s in
            var s = s
            s.title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.title.isEmpty else { return nil }
            s.prompt = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            s.check = s.check.trimmingCharacters(in: .whitespacesAndNewlines)
            s.checkCommand = s.checkCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            s.maxAttempts = clampAttempts(s.maxAttempts)
            return s
        }
        l.currentStep = min(l.currentStep, max(0, l.steps.count - 1))
        return l
    }

    /// Wipe step state so a new pass starts clean. Keeps what was configured.
    public static func resetSteps(_ steps: [LoopStep]) -> [LoopStep] {
        steps.map { s in
            var s = s
            s.state = .pending
            s.attempts = 0
            s.sessionId = nil
            s.checkSessionId = nil
            s.lastFail = nil
            return s
        }
    }

    // MARK: Prompts

    /// What to say to the agent doing the work, including why the last try failed.
    public static func workPrompt(loop: AgentLoop, step: LoopStep) -> String {
        var parts = [loop.detail.isEmpty
            ? "Goal of this loop: \(loop.title)"
            : "Goal of this loop: \(loop.title)\n\(loop.detail)"]
        parts.append("Step \(loop.currentStep + 1) of \(loop.steps.count): \(step.title)")
        if !step.prompt.isEmpty { parts.append(step.prompt) }
        if !step.checkCommand.isEmpty {
            parts.append("This step will be checked by running: \(step.checkCommand)\nThat command has to exit 0. Nothing you say about it counts.")
        }
        if !step.check.isEmpty { parts.append("This step is finished when: \(step.check)") }
        // A later pass has to know it is one: every step passed its own check last time round and
        // the goal was still not met, so repeating the first pass exactly cannot work.
        if loop.pass > 1, let why = loop.lastGoalFail {
            parts.append("This is pass \(loop.pass) of \(loop.maxPasses) over the whole loop. Last time every step passed its own check but the goal was still not met: \(why)")
        }
        if let why = step.lastFail {
            // The reason travels with the retry, and so does a scope line: without one a returned
            // step grows, fixing adjacent problems in steps that already passed their checks.
            parts.append([
                "A previous attempt did not pass the check.",
                "WHAT FAILED: \(step.title)",
                "WHY: \(why)",
                "SCOPE: fix exactly that and nothing else. The other steps of this loop already passed their own checks — do not redo them, do not tidy them, and do not take on work this step did not ask for."
            ].joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// What to say to whoever is grading a step.
    public static func checkPrompt(loop: AgentLoop, step: LoopStep, sameSession: Bool, folder: String) -> String {
        [
            "You are checking one step of a loop, not continuing it. Do no new work: inspect what is there and judge it.",
            sameSession
                ? "Judge the work in this conversation."
                : "Judge work that was just done in \(folder) by another agent. Read whatever you need to.",
            "Step: \(step.title)",
            "It passes only if: \(step.check)",
            "Reply with one final line, exactly one of:\nVERDICT: PASS\nVERDICT: FAIL — <one sentence naming what is missing or wrong>"
        ].joined(separator: "\n\n")
    }

    /// What to say to whoever judges the whole run.
    public static func goalPrompt(loop: AgentLoop, folder: String) -> String {
        [
            "You are judging whether a whole loop met its goal, not whether one step ran. Every step already passed its own check; that is not the question. Do no new work — inspect what is there and judge it.",
            "The goal was: \(loop.title)" + (loop.detail.isEmpty ? "" : "\n\(loop.detail)"),
            "It is met only if: \(loop.goalCheck)",
            "The work was done in \(folder). Read whatever you need to.",
            "Reply with one final line, exactly one of:\nVERDICT: PASS\nVERDICT: FAIL — <one sentence naming what is still missing>"
        ].joined(separator: "\n\n")
    }

    // MARK: Verdicts

    public struct Verdict: Equatable, Sendable {
        public var pass: Bool
        public var reason: String
        /// The check command never started, as opposed to starting and saying no.
        public var couldNotRun: Bool = false

        public init(pass: Bool, reason: String, couldNotRun: Bool = false) {
            self.pass = pass
            self.reason = reason
            self.couldNotRun = couldNotRun
        }
    }

    /// Read the verdict from what the checker said. The last verdict wins, and it has to start a
    /// line: a model that restates the format it was given ("reply with VERDICT: PASS or
    /// VERDICT: FAIL") before answering must not have its own instructions read back as its
    /// answer. No verdict is a fail, never a pass — the one case where the check did not happen is
    /// the one where it must not say the step is done. It costs an attempt, which is bounded.
    public static func readVerdict(_ text: String) -> Verdict {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing at all is a different problem from the wrong words, and saying so sends the
            // user to the model rather than to a check condition that was never the problem.
            return Verdict(pass: false, reason: "The model returned nothing at all, so nothing was checked. Try another model or agent for this step.")
        }
        var last: (pass: Bool, reason: String)?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let v = parseVerdictLine(String(raw)) { last = v }
        }
        guard let last else { return Verdict(pass: false, reason: "The check did not answer PASS or FAIL.") }
        if last.pass { return Verdict(pass: true, reason: "") }
        return Verdict(pass: false, reason: last.reason.isEmpty ? "The check said this step is not done." : last.reason)
    }

    /// One line, or nil. Spaces and tabs only between tokens — never a newline.
    static func parseVerdictLine(_ line: String) -> (pass: Bool, reason: String)? {
        var s = Substring(line)
        func skipBlanks() { while let c = s.first, c == " " || c == "\t" { s.removeFirst() } }
        func eat(_ prefix: String) -> Bool {
            if s.uppercased().hasPrefix(prefix.uppercased()) { s.removeFirst(prefix.count); return true }
            return false
        }
        skipBlanks()
        // Models add list and quote markers unbidden.
        while let c = s.first, c == "-" || c == "*" || c == ">" {
            s.removeFirst()
            skipBlanks()
        }
        _ = eat("**")
        guard eat("VERDICT") else { return nil }
        _ = eat("**")
        skipBlanks()
        guard eat(":") || eat("：") else { return nil }
        skipBlanks()
        _ = eat("**")
        let pass: Bool
        if eat("PASS") { pass = true } else if eat("FAIL") { pass = false } else { return nil }
        // A word boundary: "PASSED" is not a verdict.
        if let c = s.first, c.isLetter || c.isNumber || c == "_" { return nil }
        _ = eat("**")
        skipBlanks()
        while let c = s.first, "—-–:.".contains(c) { s.removeFirst() }
        skipBlanks()
        return (pass, s.trimmingCharacters(in: .whitespaces))
    }

    /// What came back from running a check command. The caller runs the process.
    public struct CommandResult: Equatable, Sendable {
        public var exitCode: Int32?
        public var output: String
        public var timedOut: Bool
        public var timeoutSeconds: Int
        public var spawnError: String?

        public init(exitCode: Int32?, output: String, timedOut: Bool = false, timeoutSeconds: Int = 0, spawnError: String? = nil) {
            self.exitCode = exitCode
            self.output = output
            self.timedOut = timedOut
            self.timeoutSeconds = timeoutSeconds
            self.spawnError = spawnError
        }
    }

    /// Turn a finished command into a verdict. Exit 0 passes; everything else fails, and what it
    /// printed goes back with the retry as the evidence.
    public static func readCommandVerdict(_ r: CommandResult) -> Verdict {
        let raw = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = raw.count > evidenceChars ? "…" + String(raw.suffix(evidenceChars)) : raw
        // Could-not-run is not did-not-pass: one is a typo in the command, the other a bug.
        if let e = r.spawnError {
            return Verdict(pass: false, reason: "The check command could not run at all: \(e). Fix the command itself — nothing was checked.", couldNotRun: true)
        }
        if r.timedOut {
            return Verdict(pass: false, reason: "The check command was still running after \(r.timeoutSeconds)s and was stopped." + (tail.isEmpty ? "" : " It had printed:\n\(tail)"))
        }
        if r.exitCode == 0 { return Verdict(pass: true, reason: "") }
        let code = r.exitCode.map(String.init) ?? "(unknown)"
        return Verdict(pass: false, reason: "The check command exited \(code)" + (tail.isEmpty ? " and printed nothing." : ". It printed:\n\(tail)"))
    }

    // MARK: Schedule

    /// When this loop is next allowed to start itself. Measured from the last run, not from
    /// creation, so putting "every hour" on a week-old loop does not make it due the instant it is
    /// saved.
    public static func nextRunAt(_ loop: AgentLoop) -> Date? {
        guard let every = loop.everyMinutes else { return nil }
        let base = loop.lastRunAt ?? loop.scheduledAt ?? loop.createdAt
        return base.addingTimeInterval(TimeInterval(every) * 60)
    }

    public static func isDue(_ loop: AgentLoop, now: Date = Date()) -> Bool {
        // A run in flight does not want a timer starting it a second time.
        guard loop.everyMinutes != nil, loop.state != .running, let next = nextRunAt(loop) else { return false }
        return next <= now
    }

    /// What a finished run does to the schedule. Two failures in a row turn it off and say why.
    public static func afterRun(_ loop: AgentLoop, failed: Bool, now: Date = Date()) -> AgentLoop {
        var l = loop
        l.consecutiveFailures = failed ? loop.consecutiveFailures + 1 : 0
        l.lastRunAt = now
        if l.everyMinutes != nil, l.consecutiveFailures >= scheduleGiveUp {
            l.everyMinutes = nil
            l.scheduleOffReason = "Turned off after \(l.consecutiveFailures) runs in a row that did not finish. Fix what is stopping it, then switch it back on."
        }
        return l
    }
}
