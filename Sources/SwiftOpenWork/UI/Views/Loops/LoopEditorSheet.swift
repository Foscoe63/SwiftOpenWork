import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkEngine

struct LoopEditorTarget: Identifiable {
    let loop: AgentLoop
    let isNew: Bool
    var id: String { loop.id }
}

/// Four things, in the order they are decided: what you want, how it breaks up, how you will know
/// it worked, and how often. Nothing exists until Save.
struct LoopEditorSheet: View {
    @ObservedObject var appState: AppState
    let target: LoopEditorTarget
    let onClose: () -> Void

    @State private var draft: AgentLoop

    init(appState: AppState, target: LoopEditorTarget, onClose: @escaping () -> Void) {
        self.appState = appState
        self.target = target
        self.onClose = onClose
        _draft = State(initialValue: target.loop)
    }

    private var theme: AppTheme { appState.settings.theme }

    /// How often a loop may start itself. Nil is the honest default: nothing runs until Run.
    private static let everyChoices: [(label: String, minutes: Int?)] = [
        ("Only when I run it", nil),
        ("Every 15 minutes", 15),
        ("Hourly", 60),
        ("Daily", 60 * 24)
    ]

    // A check should only read. This is deliberately narrow: it asks whether the thing about to
    // run unattended looks like it changes something, not whether it needs approval — which would
    // flag `npm test`, the most common check anybody writes, and teach people to ignore the warning.
    private static let destructivePattern =
        #"\brm\s+-|\bsudo\b|\bdd\s+if=|\bmkfs|\bshutdown\b|\breboot\b|\bgit\s+push\b|\bgit\s+reset\s+--hard\b|\bgit\s+clean\b|\bnpm\s+publish\b|>\s*/(dev|etc|usr|bin|sys)\b|\|\s*(sudo\s+)?(sh|bash|zsh)\b"#

    private static func looksDestructive(_ command: String) -> Bool {
        command.range(of: destructivePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.steps.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.isNew ? "New loop" : "Edit loop")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    goalSection
                    stepsSection
                    finishSection
                }
                .padding(22)
            }

            Divider()
            HStack {
                if !canSave {
                    Text("A loop needs a goal and at least one step with a title.")
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(ThemeColors.accent(for: appState.settings.accentColor))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 620, idealHeight: 760)
        .background(ThemeColors.bg(for: theme))
    }

    // MARK: 1 · The goal

    private var goalSection: some View {
        section("1 · The goal", "What should be true when this is finished?") {
            TextField("e.g. The app builds and every test passes", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            TextField("Anything else every step should know (optional)", text: $draft.detail, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Folder (empty uses this workspace’s folder)", text: $draft.cwd)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseFolder() }
            }
        }
    }

    // MARK: 2 · The steps

    private var stepsSection: some View {
        section("2 · The steps", "In order. A step starts only when the one before it has passed.") {
            ForEach($draft.steps) { $step in
                let number = (draft.steps.firstIndex { $0.id == step.id } ?? 0) + 1
                stepEditor($step, number: number)
            }
            Button {
                draft.steps.append(LoopStep())
            } label: {
                Label("Add step", systemImage: "plus")
            }
        }
    }

    private func stepEditor(_ step: Binding<LoopStep>, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                Spacer()
                if draft.steps.count > 1 {
                    Button("Remove") { draft.steps.removeAll { $0.id == step.wrappedValue.id } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5))
                }
            }
            TextField("What this step does", text: step.title)
                .textFieldStyle(.roundedBorder)
            TextField("Add detail — anything else the agent should know (optional)", text: step.prompt, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)

            // The command goes above the sentence, because that is the order it runs in and the
            // order it deserves: a program can evaluate it, and a model can only guess.
            VStack(alignment: .leading, spacing: 4) {
                Text("This step passes when this command exits 0 (optional)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                TextField("e.g. swift test", text: step.checkCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text(step.wrappedValue.checkCommand.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "A command that exits 0 is the only kind of check that cannot be argued with. Two models agreeing is not a check."
                     : "Runs in the folder above. Exit 0 passes; anything else fails, and what it printed goes back with the retry. It runs before any agent is asked, so a failing command costs nothing.")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                    .fixedSize(horizontal: false, vertical: true)
                if Self.looksDestructive(step.wrappedValue.checkCommand) {
                    Text("That looks like it changes something. A check should only read — and on a schedule it runs with nobody watching.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("…and when an agent agrees that (optional)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                TextField("e.g. the README explains how to install it", text: step.check, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 16) {
                agentPicker("Done by", selection: step.agentId)
                if !step.wrappedValue.check.trimmingCharacters(in: .whitespaces).isEmpty {
                    agentPicker("Checked by", selection: step.checkAgentId, nilLabel: "Same agent")
                }
                Stepper(value: step.maxAttempts, in: 1...LoopRules.maxAttempts) {
                    Text("Tries: \(step.wrappedValue.maxAttempts)")
                        .font(.system(size: 11.5))
                }
                .fixedSize()
            }

            if !step.wrappedValue.isChecked {
                Text("No check — this step will count as done the moment the agent stops. Nothing verifies it.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(ThemeColors.cardBg(for: theme)))
    }

    private func agentPicker(_ label: String, selection: Binding<String?>, nilLabel: String = "Current agent") -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11.5))
            Picker(label, selection: selection) {
                Text(nilLabel).tag(String?.none)
                ForEach(appState.agents) { agent in
                    Text(agent.name).tag(String?.some(agent.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: 3 · Done, and how often

    private var finishSection: some View {
        section("3 · Done, and how often", "Every step passing is not always the goal being met. Optionally, check the whole thing.") {
            VStack(alignment: .leading, spacing: 4) {
                Text("The whole goal passes when this command exits 0 (optional)")
                    .font(.system(size: 11.5, weight: .medium))
                TextField("e.g. swift build", text: $draft.goalCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if Self.looksDestructive(draft.goalCommand) {
                    Text("That looks like it changes something. A check should only read.")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("…and when an agent agrees that (optional)")
                    .font(.system(size: 11.5, weight: .medium))
                TextField("e.g. the feature works end to end", text: $draft.goalCheck, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }
            if draft.hasGoalCheck {
                Stepper(value: $draft.maxPasses, in: 1...LoopRules.maxPasses) {
                    Text("If the goal fails, go back to step one — up to \(draft.maxPasses) pass\(draft.maxPasses == 1 ? "" : "es")")
                        .font(.system(size: 11.5))
                }
                .fixedSize()
            }

            Divider().padding(.vertical, 4)

            HStack(spacing: 8) {
                Text("Run").font(.system(size: 11.5, weight: .medium))
                Picker("Run", selection: everyBinding) {
                    ForEach(Array(Self.everyChoices.enumerated()), id: \.offset) { _, choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("A schedule only fires while SwiftOpenWork is open. Two failed runs in a row switch it off, so a loop that cannot pass does not repeat itself all night.")
                .font(.system(size: 11))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Picker tags must be one of the offered values; an interval set some other way reads as
    /// the nearest offered one rather than an unselected menu.
    private var everyBinding: Binding<Int?> {
        Binding(
            get: {
                guard let m = draft.everyMinutes else { return nil }
                return Self.everyChoices.compactMap(\.minutes).min { abs($0 - m) < abs($1 - m) }
            },
            set: { newValue in
                draft.everyMinutes = newValue
                // A schedule measures from the moment it is set, so "hourly" on a week-old loop
                // does not fire the instant it is saved.
                draft.scheduledAt = newValue == nil ? nil : Date()
                if newValue != nil {
                    draft.scheduleOffReason = nil
                    draft.consecutiveFailures = 0
                }
            }
        )
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
            }
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            draft.cwd = url.path
        }
    }

    private func save() {
        var loop = LoopRules.normalized(draft)
        // Editing a loop that has been run leaves its history alone; running it again resets the
        // steps. A brand-new step in an old loop starts pending like the rest.
        if target.isNew { loop.createdAt = Date() }
        appState.saveLoop(loop)
        onClose()
    }
}
