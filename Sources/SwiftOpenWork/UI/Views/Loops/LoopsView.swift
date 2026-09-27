import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkEngine

/// One goal, several steps, and a check on each.
///
/// Without the check this is a task list with a different icon. A step here is done when a
/// condition the user wrote is met — a command that exits 0, and optionally a sentence an agent
/// judges in a separate turn — and a step that fails goes round again carrying the reason it
/// failed. That retry is the whole idea.
public struct LoopsView: View {
    @ObservedObject var appState: AppState
    @State private var editorTarget: LoopEditorTarget?
    @State private var pendingDelete: AgentLoop?

    public init(appState: AppState) {
        self.appState = appState
    }

    private var theme: AppTheme { appState.settings.theme }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                overview
                if appState.loops.isEmpty {
                    emptyState
                    LoopHowTo(appState: appState)
                } else {
                    loopList
                    DisclosureGroup {
                        LoopHowTo(appState: appState, showsHeading: false)
                            .padding(.top, 8)
                    } label: {
                        Text("How to use loops")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ThemeColors.textPrimary(for: theme))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ThemeColors.bg(for: theme))
        .sheet(item: $editorTarget) { target in
            LoopEditorSheet(appState: appState, target: target) { editorTarget = nil }
        }
        .confirmationDialog(
            "Delete this loop?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { loop in
            Button("Delete “\(loop.title)”", role: .destructive) { appState.deleteLoop(loop) }
        } message: { _ in
            Text("The chats it created stay in your session list.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Loops")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                Text("A run of steps with a check on each. A step that fails its check goes round again with the reason attached — and a check can be a command that has to exit 0, which is the only kind that cannot be argued with. Steps run as ordinary chats, so you can open any of them. A loop runs unattended: a tool call that needs your approval is refused and named, not waited on.")
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            Spacer()
            Button {
                editorTarget = LoopEditorTarget(loop: newLoop(), isNew: true)
            } label: {
                Label("New loop", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
        }
    }

    private func newLoop() -> AgentLoop {
        AgentLoop(
            workspaceId: appState.currentWorkspace.id,
            title: "",
            steps: [LoopStep()]
        )
    }

    // MARK: Observe / Act / Verify

    private var overview: some View {
        HStack(alignment: .center, spacing: 32) {
            LoopDiagramView(theme: theme, accent: appState.settings.accentColor)
                .frame(width: 320, height: 210)
            VStack(alignment: .leading, spacing: 10) {
                definition("Act", "Do the step. One goal, in one folder, in one conversation you can watch.")
                definition("Observe", "Read what actually happened — what the tests printed, what is on disk — not what was expected.")
                definition("Verify", "A separate turn judges the step against your condition. Point it at something checkable — a command that exits 0, a file that exists — because “it looks right” is an opinion, and an opinion is what a loop exists to replace.")
                definition("Stop rule", "A goal, not a step count. The loop ends when the check passes, or when the step runs out of the attempts you allowed it.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ThemeColors.cardBg(for: theme)))
    }

    private func definition(_ term: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(term)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: theme))
                .frame(width: 62, alignment: .leading)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing running yet.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: theme))
            Text("A task is one job. A loop is several, in order, each with a condition it has to meet before the next one starts — write the build step, then “passes when npm test exits 0”, and it will keep going until it does or until it runs out of attempts.")
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
        }
    }

    // MARK: Loops

    private var loopList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(appState.loops) { loop in
                LoopCard(
                    appState: appState,
                    loop: loop,
                    onEdit: { editorTarget = LoopEditorTarget(loop: loop, isNew: false) },
                    onDelete: { pendingDelete = loop }
                )
            }
        }
    }
}

// MARK: - Step by step

/// The instructions for using a loop, in the order a person does the things.
struct LoopHowTo: View {
    @ObservedObject var appState: AppState
    var showsHeading = true

    private var theme: AppTheme { appState.settings.theme }

    private static let steps: [(title: String, body: String)] = [
        ("Press New loop.",
         "A form opens. Nothing runs until you press Run on the loop afterwards."),
        ("Write the goal.",
         "One sentence saying what should be true when the loop is finished — for example “The app builds and every test passes.” This is the loop’s name, and every step is shown it."),
        ("Choose the folder.",
         "The folder the agents work in and your check commands run in. Leave it empty to use the current workspace’s folder."),
        ("Add the steps, in order.",
         "Each step is one job: “Write the parser”, then “Add tests for it”. A step only starts once the one before it has passed. Use “Add detail” for anything the agent should know that the title does not say."),
        ("Give every step a check.",
         "This is what makes it a loop. The strongest check is a command that has to exit 0 — `swift test`, `npm test`, `test -f README.md`. It runs first, costs nothing, and cannot be talked out of its answer. You can add a sentence as well — “the README explains how to install” — and a second agent will judge it. A step with no check is done the moment the agent stops talking, and nothing verifies it."),
        ("Say how many tries a step gets.",
         "Three by default. When a step fails, it goes round again with what failed and why — including the last lines the command printed. When it runs out of tries the loop stops, so a step that cannot pass cannot spend the night trying."),
        ("Optionally, check the whole goal.",
         "Every step passing does not always mean the goal was met. Add a goal check and, if it fails, the loop goes back to step one carrying the reason, up to the number of passes you allow."),
        ("Optionally, put it on a schedule.",
         "Choose how often it may start itself. It only fires while SwiftOpenWork is open, and two failed runs in a row switch it off."),
        ("Save, then press Run.",
         "Each step moves from Waiting to Working to Checking to Passed. Every turn is a real chat: press “Open chat” on a step to read what the agent did and what the checker said."),
        ("When it stops, read why.",
         "Finished means every check passed. Stopped shows the reason under the step that failed. Fix what it names — the command, the step, or the folder — then press Run again. Stop ends a run after the turn in progress.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                Text("How to use a loop")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
            }
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(ThemeColors.textPrimary(for: theme))
                        Text(.init(item.body))
                            .font(.system(size: 12))
                            .foregroundColor(ThemeColors.textSecondary(for: theme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Good to know")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                note("A loop runs with nobody watching. A tool call that needs your approval is refused, and the refusal is named in the failure reason.")
                note("Loops run one at a time, and only while the app is open.")
                note("A check command should only read. It runs on your machine, in your folder, and on a schedule it runs unattended.")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundColor(ThemeColors.textSecondary(for: theme))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - A loop on the board

struct LoopCard: View {
    @ObservedObject var appState: AppState
    let loop: AgentLoop
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var theme: AppTheme { appState.settings.theme }
    private var accent: Color { ThemeColors.accent(for: appState.settings.accentColor) }
    private var running: Bool { loop.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loop.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                    HStack(spacing: 6) {
                        Text(stateLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(stateColor)
                        if running, loop.maxPasses > 1 {
                            Text("· pass \(loop.pass) of \(loop.maxPasses)")
                                .font(.system(size: 11))
                                .foregroundColor(ThemeColors.textSecondary(for: theme))
                        }
                        if let every = loop.everyMinutes {
                            Text("· every \(Self.everyLabel(every))")
                                .font(.system(size: 11))
                                .foregroundColor(ThemeColors.textSecondary(for: theme))
                        }
                    }
                }
                Spacer()
                if running {
                    Button {
                        LoopRunner.shared.stop(loopId: loop.id, appState: appState)
                    } label: {
                        Label("Stop", systemImage: "stop.fill").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        LoopRunner.shared.start(loopId: loop.id, appState: appState)
                    } label: {
                        Label(loop.state == .idle && loop.lastRunAt == nil ? "Run" : "Run again", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    Button(action: onEdit) { Image(systemName: "pencil") }
                        .buttonStyle(.bordered)
                        .help("Edit this loop")
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.bordered)
                        .help("Delete this loop")
                }
            }

            if !loop.detail.isEmpty {
                Text(loop.detail)
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
            }

            if let outcome = loop.lastOutcome, !running, loop.state != .done {
                Text(outcome)
                    .font(.system(size: 11.5))
                    .foregroundColor(loop.state == .failed ? .red : ThemeColors.textSecondary(for: theme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = loop.scheduleOffReason, loop.everyMinutes == nil {
                Text(why)
                    .font(.system(size: 11.5))
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(loop.steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(index: index, step: step)
                }
            }

            if loop.hasGoalCheck {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whole goal passes when")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                    if !loop.goalCommand.isEmpty {
                        Text("`\(loop.goalCommand)` exits 0").font(.system(size: 11.5)).foregroundColor(ThemeColors.textSecondary(for: theme))
                    }
                    if !loop.goalCheck.isEmpty {
                        Text(loop.goalCheck).font(.system(size: 11.5)).foregroundColor(ThemeColors.textSecondary(for: theme))
                    }
                    if let id = loop.goalSessionId {
                        openChat(id)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ThemeColors.cardBg(for: theme)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(running ? accent.opacity(0.6) : ThemeColors.border(for: theme), lineWidth: 1)
        )
    }

    private func stepRow(index: Int, step: LoopStep) -> some View {
        let current = running && index == loop.currentStep
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color(for: step.state))
                .frame(width: 22, height: 22)
                .background(Circle().fill(color(for: step.state).opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(step.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                    Spacer()
                    Text(step.state.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(color(for: step.state))
                }
                Text(whoLabel(step))
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                if !step.checkCommand.isEmpty {
                    Text("Passes when `\(step.checkCommand)` exits 0")
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                if !step.check.isEmpty {
                    Text((step.checkCommand.isEmpty ? "Passes when " : "and when ") + step.check)
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                // Say it out loud: a step with no condition is finished the moment the agent
                // stops, which is exactly the weakness a loop exists to fix.
                if !step.isChecked {
                    Text("No check — this step is done when the agent stops. Nothing verifies it.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.orange)
                }
                if let why = step.lastFail, step.state != .passed {
                    Text("Last check said: \(why)")
                        .font(.system(size: 11.5))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let id = step.sessionId {
                    openChat(id)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? accent.opacity(0.08) : Color.clear))
    }

    private func openChat(_ sessionId: String) -> some View {
        Button {
            guard let session = appState.sessions.first(where: { $0.id == sessionId }) else {
                appState.showToast("That chat is no longer in your session list.")
                return
            }
            appState.selectSession(session)
            appState.navigationDestination = .chat
        } label: {
            Text("Open chat")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accent)
        }
        .buttonStyle(.hitTestable)
    }

    private func whoLabel(_ step: LoopStep) -> String {
        let doer = step.agentId.flatMap { id in appState.agents.first { $0.id == id }?.name } ?? "Current agent"
        var label = step.agentId != nil && appState.agents.first(where: { $0.id == step.agentId }) == nil ? "Missing agent" : doer
        if let checker = step.checkAgentId {
            label += " · checked by " + (appState.agents.first { $0.id == checker }?.name ?? "a missing agent")
        }
        if step.attempts > 1 || step.state == .failed {
            label += " · attempt \(step.attempts) of \(step.maxAttempts)"
        }
        return label
    }

    private var stateLabel: String {
        if loop.state == .failed && loop.failedOnGoal { return "Stopped — every step passed but the goal did not" }
        if loop.state == .failed { return "Stopped — a step could not pass its check" }
        return loop.state.label
    }

    private var stateColor: Color {
        switch loop.state {
        case .running: return accent
        case .done: return .green
        case .failed: return .red
        case .idle: return ThemeColors.textSecondary(for: theme)
        }
    }

    private func color(for state: LoopStepState) -> Color {
        switch state {
        case .pending: return ThemeColors.textSecondary(for: theme)
        case .working, .checking: return accent
        case .passed: return .green
        case .failed: return .red
        }
    }

    /// "every 1 hour" is not how anyone says it. One of anything drops the number.
    static func everyLabel(_ mins: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? word : "\(n) \(word)s" }
        if mins % (60 * 24) == 0 { return unit(mins / (60 * 24), "day") }
        if mins % 60 == 0 { return unit(mins / 60, "hour") }
        return "\(mins) min"
    }
}

// MARK: - Observe → Act → Verify

/// The three-part cycle, drawn: act, observe what happened, verify it, and go round again until
/// the check passes.
struct LoopDiagramView: View {
    let theme: AppTheme
    let accent: AccentColorChoice

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let observe = CGPoint(x: w * 0.5, y: h * 0.16)
            let act = CGPoint(x: w * 0.82, y: h * 0.72)
            let verify = CGPoint(x: w * 0.18, y: h * 0.72)
            let center = CGPoint(x: w * 0.5, y: h * 0.52)
            ZStack {
                // Observe → Act → Verify → Observe, each leg bowed out from the middle.
                arrow(from: observe, to: act, bow: center, in: geo.size)
                arrow(from: act, to: verify, bow: center, in: geo.size)
                arrow(from: verify, to: observe, bow: center, in: geo.size)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22))
                    .foregroundColor(ThemeColors.textSecondary(for: theme).opacity(0.5))
                    .position(center)

                node("Observe", "eye", at: observe)
                node("Act", "bolt", at: act, labelOnRight: true)
                node("Verify", "checkmark", at: verify, labelOnLeft: true)

                Text("repeat until\nthe check passes")
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                    .position(x: w * 0.5, y: h * 0.92)
            }
        }
    }

    private func node(_ label: String, _ symbol: String, at p: CGPoint, labelOnRight: Bool = false, labelOnLeft: Bool = false) -> some View {
        let circle = Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(ThemeColors.textPrimary(for: theme))
            .frame(width: 38, height: 38)
            .background(Circle().fill(ThemeColors.bg(for: theme)))
            .overlay(Circle().stroke(ThemeColors.textSecondary(for: theme).opacity(0.7), lineWidth: 1))
        let text = Text(label)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(ThemeColors.textPrimary(for: theme))
        return Group {
            if labelOnRight {
                HStack(spacing: 8) { circle; text }
            } else if labelOnLeft {
                HStack(spacing: 8) { text; circle }
            } else {
                VStack(spacing: 6) { text; circle }
            }
        }
        .position(p)
    }

    /// A curve from `a` to `b` pulled away from `middle`, ending in an arrowhead a little short of
    /// the node so it does not run under the circle.
    private func arrow(from a: CGPoint, to b: CGPoint, bow middle: CGPoint, in size: CGSize) -> some View {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Push the control point away from the centre so each leg bulges outward.
        let dx = mid.x - middle.x, dy = mid.y - middle.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        let control = CGPoint(x: mid.x + dx / len * 34, y: mid.y + dy / len * 34)
        let start = Self.inset(a, toward: control, by: 26)
        let end = Self.inset(b, toward: control, by: 30)
        return Path { p in
            p.move(to: start)
            p.addQuadCurve(to: end, control: control)
            // Arrowhead, oriented along the end of the curve.
            let angle = atan2(end.y - control.y, end.x - control.x)
            let head: CGFloat = 7
            p.move(to: end)
            p.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6)))
            p.move(to: end)
            p.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6)))
        }
        .stroke(ThemeColors.textSecondary(for: theme).opacity(0.7), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    private static func inset(_ p: CGPoint, toward q: CGPoint, by d: CGFloat) -> CGPoint {
        let dx = q.x - p.x, dy = q.y - p.y
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: p.x + dx / len * d, y: p.y + dy / len * d)
    }
}
