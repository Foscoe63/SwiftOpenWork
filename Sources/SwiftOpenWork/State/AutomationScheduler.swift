import Foundation
import Combine
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Fires automations. This is the thing that did not exist.
///
/// `AutomationTriggerType` declares five triggers — manual, scheduled, onStartup, onSessionCreated,
/// fileWatch. Before this file, exactly one of them ran anything, and only because the user pressed
/// a button. The other four were an enum, an icon and a display name. The Automations screen drew
/// "Next run: Tomorrow at 9:00 AM" from a string-matching heuristic and nothing ever came.
///
/// Four rules this scheduler keeps, each of them a way the naive version goes wrong:
///
/// 1. **No catch-up storms.** Next fire is computed from `lastRunAt`, and firing sets `lastRunAt`
///    to now. An app closed over a weekend comes back to one overdue run of an hourly automation,
///    not forty-eight.
/// 2. **No overlap.** An automation already running is not started again, and runs are serialised
///    against each other. A local model serves one turn at a time; two concurrent turns would
///    queue inside MLX and land as one mysterious stall.
/// 3. **Never over the user.** While a chat turn is generating, due automations wait for the next
///    tick. The user's turn is the one with someone watching it.
/// 4. **A run that fails is recorded as failed.** `recordAutomationRun` is the only writer of
///    `lastStatus`, so a schedule cannot report success for a turn that refused.
@MainActor
public final class AutomationScheduler: ObservableObject {

    public static let shared = AutomationScheduler()

    /// How often to look for due automations.
    ///
    /// Thirty seconds, not one: the finest schedule the parser accepts is `everyMinutes(1)`, and a
    /// tick twice per minute resolves it without waking the process sixty times an hour.
    static let tickInterval: TimeInterval = 30

    private var timer: Timer?
    private var running: Set<String> = []
    private var startupDone = false
    private weak var appState: AppState?

    private var fileMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private var fileDebounce: [String: Timer] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// True when this process is an XCTest host.
    ///
    /// The unit tests run inside the app, so the app launches, its window appears, and `start`
    /// is called — against the real Application Support data. Before this guard every test run
    /// fired the user's enabled startup automations: real agent turns, a new session each, and a
    /// rewritten `lastRunAt`, from `xcodebuild test`.
    nonisolated static var isHostedByTests: Bool { AppIdentity.isHostedByTests }

    /// Begin scheduling. Safe to call twice; the second call replaces the first.
    public func start(appState: AppState) {
        guard !Self.isHostedByTests else { return }
        self.appState = appState
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        rebuildFileWatches()

        // Startup automations run once per launch, after the first tick rather than during
        // `start`, so a crash loop in one of them cannot stop the app from finishing launch.
        Task { @MainActor in
            await runStartupAutomations()
            await tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for (_, source) in fileMonitors { source.cancel() }
        fileMonitors.removeAll()
        for (_, debounce) in fileDebounce { debounce.invalidate() }
        fileDebounce.removeAll()
    }

    /// Call when the automation list changes, so file watches follow the edit.
    public func automationsChanged() {
        rebuildFileWatches()
    }

    // MARK: - Triggers

    /// Whether one automation is due. Pure, and separated from `AppState` so it can be tested:
    /// this predicate is the whole scheduler, and the rest is plumbing around it.
    ///
    /// Measured from `lastRunAt` — falling back to `createdAt`, never to "now", which would make
    /// every automation permanently one interval away from its first run.
    static func isDue(_ automation: Automation, now: Date, calendar: Calendar = .current) -> Bool {
        guard automation.isEnabled, automation.triggerType == .scheduled else { return false }
        guard let next = AutomationSchedule.nextFireDate(
            after: automation.lastRunAt ?? automation.createdAt,
            schedule: automation.cronSchedule,
            calendar: calendar
        ) else { return false }        // Unrecognised schedules never fire. The card says so.
        return next <= now
    }

    /// Everything due right now, longest-waiting first.
    func dueAutomations(now: Date = Date()) -> [Automation] {
        guard let appState else { return [] }
        return appState.automations
            .filter { !running.contains($0.id) && Self.isDue($0, now: now) }
            .sorted { ($0.lastRunAt ?? $0.createdAt) < ($1.lastRunAt ?? $1.createdAt) }
    }

    private func tick() async {
        guard let appState else { return }
        // Rule 3: the user's turn wins. These are minutes-granular schedules; waiting one tick
        // costs nothing and competing for the model costs a stalled chat.
        guard !appState.isGenerating else { return }

        for automation in dueAutomations() {
            await run(automation, trigger: "schedule")
        }
    }

    private func runStartupAutomations() async {
        guard !startupDone, let appState else { return }
        startupDone = true
        for automation in appState.automations where automation.isEnabled && automation.triggerType == .onStartup {
            await run(automation, trigger: "app launch")
        }
    }

    /// Called by `AppState` when a session is created.
    public func sessionWasCreated() {
        guard let appState else { return }
        let matching = appState.automations.filter { $0.isEnabled && $0.triggerType == .onSessionCreated }
        guard !matching.isEmpty else { return }
        Task { @MainActor in
            for automation in matching {
                await run(automation, trigger: "new session")
            }
        }
    }

    // MARK: - File watching

    private func rebuildFileWatches() {
        for (_, source) in fileMonitors { source.cancel() }
        fileMonitors.removeAll()

        guard let appState else { return }
        for automation in appState.automations
        where automation.isEnabled && automation.triggerType == .fileWatch {
            guard let path = automation.watchPath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename],
                queue: DispatchQueue.global(qos: .utility)
            )
            let id = automation.id
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.fileEventArrived(automationId: id) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            fileMonitors[id] = source
        }
    }

    /// Debounced: a save from an editor is several filesystem events, and an agent turn per
    /// keystroke-flush is the failure mode that makes people switch the feature off.
    private func fileEventArrived(automationId: String) {
        fileDebounce[automationId]?.invalidate()
        fileDebounce[automationId] = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let appState = self.appState,
                      let automation = appState.automations.first(where: { $0.id == automationId }),
                      automation.isEnabled else { return }
                await self.run(automation, trigger: "file change")
            }
        }
    }

    // MARK: - Running

    /// Run one automation through the same headless path Shortcuts uses.
    ///
    /// Deliberately not a second execution path: `HeadlessAgentTurn` already records the run as a
    /// real session the user can open and audit, and already refuses approvals rather than hanging
    /// on a dialog nobody is watching.
    func run(_ automation: Automation, trigger: String) async {
        guard let appState, !running.contains(automation.id) else { return }
        running.insert(automation.id)
        defer { running.remove(automation.id) }

        // Claim the slot before the turn starts. A run that crashes the process should not come
        // back due, and a `lastRunAt` written only on success would re-fire a failing automation
        // every tick forever. The status is "running", not "success": if the app quits now, the
        // next launch marks this run interrupted instead of leaving a success nothing produced.
        appState.recordAutomationRunStarted(id: automation.id, summary: "Started by \(trigger)…")

        let automationId = automation.id
        let result = await HeadlessAgentTurn.run(
            prompt: automation.promptTemplate,
            title: automation.name,
            appState: appState,
            agentId: automation.targetAgentId,
            continueSessionId: automation.continueConversation == true ? automation.lastSessionId : nil,
            onSessionStarted: { sessionId in
                appState.recordAutomationSession(id: automationId, sessionId: sessionId)
            }
        )

        let succeeded = !result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let summary: String
        if !succeeded {
            summary = "Started by \(trigger); the run produced no reply."
        } else if result.skipped.isEmpty {
            summary = "Ran from \(trigger)."
        } else {
            summary = "Ran from \(trigger); \(result.skipped.count) action(s) skipped for want of approval."
        }
        appState.recordAutomationRun(id: automation.id, succeeded: succeeded, summary: summary)
    }
}
