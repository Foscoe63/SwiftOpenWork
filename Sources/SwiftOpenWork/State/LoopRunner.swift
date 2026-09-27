import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkEngine

/// Drives a loop: do a step, check it, and go round again with the reason if it failed.
///
/// There is still one execution path. Every turn here is a `HeadlessAgentTurn`, so it uses the
/// same agent runner, tools and sandbox as a chat, and is recorded as a real session the user can
/// open from the step. What this type adds is only the bookkeeping between turns; what a verdict
/// means and what a retry says live in `LoopRules`, where they can be tested without a model.
///
/// Two things it deliberately does not do:
/// - It does not prompt for approval. A loop runs unattended, so a tool call that needs a person
///   is refused and named in the failure reason, exactly as an automation's is.
/// - It does not run with the app closed. A schedule only fires while SwiftOpenWork is open, and
///   the Loops screen says so beside the control.
@MainActor
public final class LoopRunner {
    public static let shared = LoopRunner()

    private var tasks: [String: Task<Void, Never>] = [:]
    private var timer: Timer?
    private weak var schedulerAppState: AppState?

    /// How often the schedule is looked at. A loop is never due more precisely than a minute.
    static let tickInterval: TimeInterval = 30

    public func isRunning(_ loopId: String) -> Bool { tasks[loopId] != nil }

    // MARK: Scheduling

    /// Begin watching for loops that are due. Safe to call twice.
    public func startScheduler(appState: AppState) {
        // Unit tests run inside the app against the real data folder; a schedule must not fire
        // real agent turns from `xcodebuild test`.
        guard !AppIdentity.isHostedByTests else { return }
        schedulerAppState = appState
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let appState = schedulerAppState else { return }
        // One at a time: two loops at once would fight over the same model and the same folder.
        guard tasks.isEmpty, appState.backgroundRuns.isEmpty, !appState.isGenerating else { return }
        if let due = appState.loops.first(where: { LoopRules.isDue($0) && !$0.steps.isEmpty }) {
            start(loopId: due.id, appState: appState)
        }
    }

    // MARK: Start / stop

    public func start(loopId: String, appState: AppState) {
        guard tasks[loopId] == nil, let loop = appState.loops.first(where: { $0.id == loopId }) else { return }
        var fresh = LoopRules.normalized(loop)
        guard !fresh.steps.isEmpty else {
            appState.showToast("A loop needs at least one step.")
            return
        }
        fresh.steps = LoopRules.resetSteps(fresh.steps)
        fresh.currentStep = 0
        fresh.state = .running
        fresh.pass = 1
        fresh.lastGoalFail = nil
        fresh.goalSessionId = nil
        fresh.lastOutcome = nil
        fresh.lastRunAt = Date()
        appState.saveLoop(fresh)

        tasks[loopId] = Task { [weak self, weak appState] in
            guard let appState else { return }
            await self?.run(loopId: loopId, appState: appState)
            self?.tasks[loopId] = nil
        }
    }

    /// Stop after the turn in flight. A turn already handed to the model cannot be recalled, but
    /// nothing further is started, and the step goes back to waiting.
    public func stop(loopId: String, appState: AppState) {
        tasks[loopId]?.cancel()
        guard var loop = appState.loops.first(where: { $0.id == loopId }), loop.state == .running else { return }
        loop.state = .idle
        loop.lastOutcome = "Stopped by you."
        for i in loop.steps.indices where loop.steps[i].state == .working || loop.steps[i].state == .checking {
            loop.steps[i].state = .pending
        }
        appState.saveLoop(loop)
    }

    // MARK: The run

    private enum Outcome {
        case done
        case failed(String)
        case cancelled
    }

    private func run(loopId: String, appState: AppState) async {
        let outcome = await runPasses(loopId: loopId, appState: appState)
        guard var loop = appState.loops.first(where: { $0.id == loopId }) else { return }
        switch outcome {
        case .cancelled:
            // `stop` already wrote the state; do not overwrite it with a second one.
            return
        case .done:
            loop.state = .done
            loop.lastOutcome = "Finished."
            loop = LoopRules.afterRun(loop, failed: false)
            appState.showToast("Loop finished: \(loop.title)")
        case .failed(let why):
            loop.state = .failed
            loop.lastOutcome = why
            loop = LoopRules.afterRun(loop, failed: true)
            appState.showToast("Loop stopped: \(loop.title)")
        }
        appState.saveLoop(loop)
    }

    /// The whole walk, one pass at a time. Reads the loop from `appState` at each transition so
    /// what the screen shows is what is on disk.
    private func runPasses(loopId: String, appState: AppState) async -> Outcome {
        func current() -> AgentLoop? { appState.loops.first { $0.id == loopId } }

        while true {
            guard var loop = current() else { return .cancelled }
            let folder = Self.folder(for: loop, appState: appState)
            let workspace = Self.workspace(for: loop, folder: folder, appState: appState)

            // MARK: steps
            while loop.currentStep < loop.steps.count {
                if Task.isCancelled { return .cancelled }
                let index = loop.currentStep
                var step = loop.steps[index]

                step.attempts += 1
                step.state = .working
                loop.steps[index] = step
                appState.saveLoop(loop)

                let work = await HeadlessAgentTurn.run(
                    prompt: LoopRules.workPrompt(loop: loop, step: step),
                    title: "\(loop.title) — \(step.title)",
                    appState: appState,
                    agentId: step.agentId,
                    workspace: workspace,
                    onSessionStarted: { id in
                        step.sessionId = id
                        loop.steps[index] = step
                        appState.saveLoop(loop)
                    }
                )
                if Task.isCancelled { return .cancelled }
                // No session means the turn never started (a provider that must be refused). No
                // retry can fix that, so say so rather than burning the attempts.
                if work.sessionId.isEmpty { return .failed(work.reply) }

                var verdict = LoopRules.Verdict(pass: true, reason: "")

                // The command goes first and the opinion goes last: a command that exits 0 settles
                // the question for free, and a model asked afterwards can only agree with it.
                if !step.checkCommand.isEmpty {
                    verdict = LoopRules.readCommandVerdict(await LoopCheckCommand.run(step.checkCommand, in: folder))
                }
                if verdict.pass, !step.check.isEmpty {
                    step.state = .checking
                    loop.steps[index] = step
                    appState.saveLoop(loop)
                    let judged = await HeadlessAgentTurn.run(
                        prompt: LoopRules.checkPrompt(loop: loop, step: step, sameSession: false, folder: folder),
                        title: "Check — \(step.title)",
                        appState: appState,
                        agentId: step.checkAgentId ?? step.agentId,
                        workspace: workspace,
                        onSessionStarted: { id in
                            step.checkSessionId = id
                            loop.steps[index] = step
                            appState.saveLoop(loop)
                        }
                    )
                    if Task.isCancelled { return .cancelled }
                    if judged.sessionId.isEmpty { return .failed(judged.reply) }
                    verdict = LoopRules.readVerdict(judged.reply)
                }

                if verdict.pass {
                    step.state = .passed
                    step.lastFail = nil
                    loop.steps[index] = step
                    loop.currentStep += 1
                    appState.saveLoop(loop)
                    continue
                }

                step.lastFail = Self.withRefusals(verdict.reason, work.skipped)
                if step.attempts >= step.maxAttempts {
                    step.state = .failed
                    loop.steps[index] = step
                    appState.saveLoop(loop)
                    return .failed("“\(step.title)” did not pass its check after \(step.attempts) attempt\(step.attempts == 1 ? "" : "s"). The check said: \(step.lastFail ?? "")")
                }
                // Straight back to the work, with the reason as the evidence. A retry starts a
                // fresh conversation: reusing the old one left the failed attempt in context, and
                // the model treated its own earlier answer as settled.
                step.state = .pending
                loop.steps[index] = step
                appState.saveLoop(loop)
            }

            // MARK: goal
            // Every step passing is not the goal being met. That gap is the ceiling of a step-wise
            // loop: it can make each unit correct and still have run the wrong units.
            guard loop.hasGoalCheck else { return .done }

            var goal = LoopRules.Verdict(pass: true, reason: "")
            if !loop.goalCommand.isEmpty {
                goal = LoopRules.readCommandVerdict(await LoopCheckCommand.run(loop.goalCommand, in: folder))
            }
            if goal.pass, !loop.goalCheck.isEmpty {
                let judged = await HeadlessAgentTurn.run(
                    prompt: LoopRules.goalPrompt(loop: loop, folder: folder),
                    title: "Goal check — \(loop.title)",
                    appState: appState,
                    workspace: workspace,
                    onSessionStarted: { id in
                        loop.goalSessionId = id
                        appState.saveLoop(loop)
                    }
                )
                if Task.isCancelled { return .cancelled }
                if judged.sessionId.isEmpty { return .failed(judged.reply) }
                goal = LoopRules.readVerdict(judged.reply)
            }
            if goal.pass { return .done }

            loop.lastGoalFail = goal.reason
            if loop.pass >= loop.maxPasses {
                appState.saveLoop(loop)
                return .failed("Every step passed \(loop.pass) time\(loop.pass == 1 ? "" : "s"), and the goal was still not met: \(goal.reason)")
            }
            // Back to step one, carrying why.
            loop.pass += 1
            loop.currentStep = 0
            loop.steps = LoopRules.resetSteps(loop.steps)
            loop.goalSessionId = nil
            appState.saveLoop(loop)
        }
    }

    // MARK: Helpers

    /// The folder steps and checks run in: the loop's own, else its workspace's.
    static func folder(for loop: AgentLoop, appState: AppState) -> String {
        if !loop.cwd.isEmpty { return (loop.cwd as NSString).expandingTildeInPath }
        return appState.workspaces.first { $0.id == loop.workspaceId }?.folderPath
            ?? appState.currentWorkspace.folderPath
    }

    static func workspace(for loop: AgentLoop, folder: String, appState: AppState) -> Workspace {
        var ws = appState.workspaces.first { $0.id == loop.workspaceId } ?? appState.currentWorkspace
        ws.folderPath = folder
        return ws
    }

    /// A refused tool call is often the real reason a check failed, and the retry cannot fix it.
    static func withRefusals(_ reason: String, _ skipped: [String]) -> String {
        guard !skipped.isEmpty else { return reason }
        return reason + "\nThese actions needed approval and nothing was watching, so they were refused:\n"
            + skipped.map { "• \($0)" }.joined(separator: "\n")
    }
}
