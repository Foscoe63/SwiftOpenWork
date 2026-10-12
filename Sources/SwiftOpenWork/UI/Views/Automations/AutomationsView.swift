import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkEngine

public struct AutomationsView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddModal = false
    @State private var editingAutomation: Automation? = nil
    @State private var historyAutomation: Automation? = nil

    /// Grows column count as the panel widens (card min width ~300pt).
    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)]
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            ScrollView {
                if appState.automations.isEmpty {
                    emptyState
                        .padding(24)
                } else {
                    LazyVGrid(columns: adaptiveColumns, spacing: 20) {
                        ForEach(appState.automations) { auto in
                            AutomationCardView(
                                appState: appState,
                                automation: auto,
                                onEdit: { editingAutomation = auto },
                                onRunNow: { runAutomation(auto) },
                                onShowHistory: { historyAutomation = auto },
                                onExportSummary: { exportSummary(for: auto) },
                                onToggle: { enabled in
                                    setEnabled(auto, enabled: enabled)
                                },
                                onDelete: { deleteAutomation(auto) },
                                onSynthesizeArtifact: {
                                    appState.createArtifactFromAutomation(auto)
                                }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddModal) {
            AutomationEditorSheet(
                appState: appState,
                mode: .create,
                isPresented: $showingAddModal
            )
        }
        .sheet(item: $editingAutomation) { auto in
            AutomationEditorSheet(
                appState: appState,
                mode: .edit(auto),
                isPresented: Binding(
                    get: { editingAutomation != nil },
                    set: { if !$0 { editingAutomation = nil } }
                )
            )
        }
        .sheet(item: $historyAutomation) { auto in
            AutomationHistorySheet(appState: appState, automation: auto) {
                historyAutomation = nil
            }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Schedules")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("\(appState.automations.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(ThemeColors.border(for: appState.settings.theme).opacity(0.7))
                        )
                }
                Text("Automate recurring AI tasks with custom schedules")
                    .font(.system(size: 12))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Button {
                appState.automations = PersistenceManager.shared.loadAutomations()
                appState.showToast("Schedules refreshed")
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())

            Button {
                showingAddModal = true
            } label: {
                Label("Create Schedule", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No schedules yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
            Text("Create a schedule to run recurring agent tasks automatically.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingAddModal = true
            } label: {
                Label("Create Schedule", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// "Run now". Interactive on purpose — the user is right there, so approvals can be granted
    /// rather than refused, which is the one thing the headless path cannot do.
    ///
    /// The outcome is recorded when the turn ends, not when it starts, and through
    /// `recordAutomationRun` like every other trigger. This used to write "Completed" on the line
    /// after `sendMessage`, which reported success before a token was generated — and reported it
    /// even when `sendMessage` returned early because another turn was already running.
    private func runAutomation(_ auto: Automation) {
        guard !appState.isGenerating else {
            appState.showToast("Busy — finish the current turn first")
            return
        }
        appState.showToast("Running: \(auto.name)")
        appState.createNewSession(agentId: auto.targetAgentId)
        appState.recordAutomationRunStarted(
            id: auto.id, summary: "Started from Run now…", sessionId: appState.currentSessionId
        )
        appState.sendMessage(text: auto.promptTemplate) { ran in
            appState.recordAutomationRun(
                id: auto.id,
                succeeded: ran,
                summary: ran ? "Ran from Run now." : "Run now did not start — a turn was already in flight."
            )
        }
    }

    private func setEnabled(_ auto: Automation, enabled: Bool) {
        guard let idx = appState.automations.firstIndex(where: { $0.id == auto.id }) else { return }
        appState.automations[idx].isEnabled = enabled
        appState.automations[idx].updatedAt = Date()
        PersistenceManager.shared.saveAutomations(appState.automations)
        AutomationScheduler.shared.automationsChanged()
        appState.showToast(enabled ? "Schedule resumed" : "Schedule paused")
    }

    private func deleteAutomation(_ auto: Automation) {
        appState.automations.removeAll(where: { $0.id == auto.id })
        PersistenceManager.shared.saveAutomations(appState.automations)
        AutomationScheduler.shared.automationsChanged()
        appState.showToast("Schedule deleted")
    }

    private func exportSummary(for auto: Automation) {
        let agentName = appState.agents.first(where: { $0.id == auto.targetAgentId })?.name ?? auto.targetAgentId
        let text = """
        # \(auto.name)

        - Status: \(auto.isEnabled ? "Enabled" : "Paused")
        - Schedule: \(auto.cronSchedule)
        - Trigger: \(auto.triggerType.displayName)
        - Agent: \(agentName)
        - Last run: \(auto.lastRunAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Never")
        - Last status: \(auto.lastStatus ?? "—")

        ## Instructions
        \(auto.promptTemplate)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.showToast("Schedule summary copied")
    }
}

// MARK: - Automation Card (Osaurus-style)

private struct AutomationCardView: View {
    @ObservedObject var appState: AppState
    let automation: Automation
    let onEdit: () -> Void
    let onRunNow: () -> Void
    let onShowHistory: () -> Void
    let onExportSummary: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onSynthesizeArtifact: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var agentName: String {
        appState.agents.first(where: { $0.id == automation.targetAgentId })?.name ?? "Assistant"
    }

    private var scheduleColor: Color {
        let hue = Double(abs(automation.name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    private var accent: Color {
        ThemeColors.accent(for: appState.settings.accentColor)
    }

    private var isRunning: Bool {
        (automation.lastStatus ?? "").lowercased().contains("running")
    }

    private var lastError: String? {
        if let status = automation.lastStatus?.lowercased(),
           status.contains("error") || status.contains("fail") || status.contains("cannot")
            || status.contains("interrupted") {
            return automation.lastResultSummary ?? automation.lastStatus
        }
        if let summary = automation.lastResultSummary,
           summary.lowercased().contains("error")
            || summary.lowercased().contains("cannot")
            || summary.lowercased().contains("fail") {
            return summary
        }
        return nil
    }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                if !automation.promptTemplate.isEmpty {
                    Text(automation.promptTemplate)
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                nextRunRow

                if let lastError {
                    errorRow(lastError)
                }

                Spacer(minLength: 0)

                compactStats
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(ThemeColors.cardBg(for: appState.settings.theme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [
                                scheduleColor.opacity(isHovered ? 0.06 : 0),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered
                            ? scheduleColor.opacity(0.25)
                            : ThemeColors.border(for: appState.settings.theme),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .alert("Delete Schedule", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete \"\(automation.name)\"? This action cannot be undone.")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if isRunning {
                    Circle()
                        .fill(accent.opacity(0.2))
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [scheduleColor.opacity(0.15), scheduleColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Circle()
                        .strokeBorder(scheduleColor.opacity(0.4), lineWidth: 2)
                    Text(automation.name.prefix(1).uppercased())
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(scheduleColor)
                }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(automation.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)
                    statusBadge
                }
                Text(automation.cronSchedule.isEmpty ? automation.triggerType.displayName : automation.cronSchedule)
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(action: onRunNow) {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(isRunning)
                Button(action: onShowHistory) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button(action: onExportSummary) {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button(action: onSynthesizeArtifact) {
                    Label("Synthesize Artifact", systemImage: "sparkles")
                }
                Divider()
                Button {
                    onToggle(!automation.isEnabled)
                } label: {
                    Label(
                        automation.isEnabled ? "Pause" : "Resume",
                        systemImage: automation.isEnabled ? "pause.circle" : "play.circle"
                    )
                }
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(ThemeColors.border(for: appState.settings.theme).opacity(0.55))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isRunning {
            badgeLabel("Running", color: accent)
        } else if automation.isEnabled {
            badgeLabel("Enabled", color: Color(red: 0.25, green: 0.75, blue: 0.45))
        } else {
            badgeLabel("Paused", color: .orange)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var nextRunRow: some View {
        let preview = AutomationSchedulePreview.make(from: automation)
        return HStack(spacing: 8) {
            Image(systemName: preview.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(preview.color)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text("Next run")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.85))
                Text(preview.description)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(preview.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(preview.color.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.red)
                .frame(width: 14)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var compactStats: some View {
        HStack(spacing: 0) {
            statItem(icon: automation.triggerType.icon, text: AutomationSchedulePreview.shortFrequency(automation.cronSchedule))

            if let status = automation.lastStatus, !status.isEmpty {
                statDot
                statItem(icon: statusIcon(for: status), text: status)
            } else if automation.lastRunAt != nil {
                statDot
                statItem(icon: "checkmark.circle", text: "Completed")
            }

            statDot
            statItem(icon: "person.fill", text: agentName)

            Spacer(minLength: 0)
        }
    }

    private func statusIcon(for status: String) -> String {
        let lower = status.lowercased()
        if lower.contains("fail") || lower.contains("error") { return "xmark.circle" }
        if lower.contains("interrupted") { return "exclamationmark.circle" }
        if lower.contains("run") { return "arrow.triangle.2.circlepath" }
        return "checkmark.circle"
    }

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
    }

    private var statDot: some View {
        Circle()
            .fill(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.4))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
    }
}

// MARK: - Next-run helpers

/// What the card says about when this automation runs next.
///
/// Every string here comes from `AutomationSchedule`, which is the same code `AutomationScheduler`
/// uses to decide what to fire. That is the whole design: this screen used to compute its own
/// next-run text from a display heuristic that echoed unparseable schedules back as if they were
/// times, above a scheduler that did not exist. A card may not promise a run the app will not make.
private struct AutomationSchedulePreview {
    let description: String
    let icon: String
    let color: Color

    static func make(from automation: Automation) -> AutomationSchedulePreview {
        if !automation.isEnabled {
            return AutomationSchedulePreview(description: "Paused", icon: "pause.circle", color: .orange)
        }
        switch automation.triggerType {
        case .manual:
            return AutomationSchedulePreview(description: "Manual only", icon: "hand.tap", color: .secondary)
        case .onStartup:
            return AutomationSchedulePreview(description: "Next app launch", icon: "bolt.fill", color: .secondary)
        case .onSessionCreated:
            return AutomationSchedulePreview(description: "Next new session", icon: "plus.message.fill", color: .secondary)
        case .fileWatch:
            guard let path = automation.watchPath, !path.isEmpty else {
                return AutomationSchedulePreview(
                    description: "No folder chosen — will not run",
                    icon: "exclamationmark.triangle",
                    color: .orange
                )
            }
            return AutomationSchedulePreview(
                description: "On changes in \((path as NSString).lastPathComponent)",
                icon: "eye.circle",
                color: .secondary
            )
        case .scheduled:
            let preview = AutomationSchedule.describeNextRun(
                schedule: automation.cronSchedule,
                after: automation.lastRunAt ?? automation.createdAt
            )
            return AutomationSchedulePreview(
                description: preview.text,
                icon: preview.willRun ? "clock" : "exclamationmark.triangle",
                color: preview.willRun ? Color(red: 0.55, green: 0.35, blue: 0.95) : .orange
            )
        }
    }

    static func shortFrequency(_ schedule: String) -> String {
        AutomationSchedule.shortFrequency(schedule)
    }
}

// MARK: - Editor Sheet (Create / Edit)

public enum AutomationEditorMode {
    case create
    case edit(Automation)
}

public struct AutomationEditorSheet: View {
    @ObservedObject var appState: AppState
    let mode: AutomationEditorMode
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var triggerType: AutomationTriggerType = .scheduled
    @State private var schedule: String = "Daily at 9:00 AM"
    @State private var watchPath: String = ""
    @State private var targetAgentId: String = "lead-assistant"
    @State private var promptTemplate: String = "Scan workspace files and provide a status update."
    @State private var continueConversation = false
    @State private var isEnabled: Bool = true
    @State private var editingId: String? = nil

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(titleText)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.hitTestable)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Schedule Info")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. MorningBrief", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Enabled", isOn: $isEnabled)
                        .font(.system(size: 12))

                    sectionLabel("Trigger")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trigger Type")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $triggerType) {
                            ForEach(AutomationTriggerType.allCases, id: \.self) { t in
                                HStack {
                                    Image(systemName: t.icon)
                                    Text(t.displayName)
                                }
                                .tag(t)
                            }
                        }
                    }

                    if triggerType == .scheduled {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Frequency / Schedule")
                                .font(.system(size: 11.5, weight: .semibold))
                            TextField("e.g. Daily at 6:00 AM", text: $schedule)
                                .textFieldStyle(.roundedBorder)
                            // Validated live against the parser the scheduler uses, so an
                            // unrecognised schedule is caught here rather than silently never
                            // firing after the sheet closes.
                            if AutomationSchedule.parse(schedule) == nil {
                                Label(
                                    "Not a schedule this app can run — it will never fire.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            } else {
                                Text("Next run: \(AutomationSchedule.describeNextRun(schedule: schedule, after: Date()).text)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Text("Daily at 6:00 AM · Every 2 hours · Weekly on Monday · 0 9 * * 1-5")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    if triggerType == .fileWatch {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Watched Folder")
                                .font(.system(size: 11.5, weight: .semibold))
                            HStack(spacing: 8) {
                                TextField("Choose a folder to watch", text: $watchPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose…") { chooseWatchFolder() }
                                    .buttonStyle(.bordered)
                            }
                            if watchPath.trimmingCharacters(in: .whitespaces).isEmpty {
                                Label(
                                    "No folder chosen — this automation will never fire.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            } else {
                                Text("Runs a few seconds after changes settle, not per keystroke.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    sectionLabel("Agent")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Assigned Agent")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $targetAgentId) {
                            ForEach(appState.agents) { ag in
                                Text(ag.name).tag(ag.id)
                            }
                        }
                    }

                    sectionLabel("Instructions")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt / Step-by-step Instructions")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextEditor(text: $promptTemplate)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(minHeight: 140)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }

                    Toggle(isOn: $continueConversation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue the same conversation each run")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("The agent sees what it said last time. Off: every run starts fresh.")
                                .font(.system(size: 10.5)).foregroundColor(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description (optional)")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("Short note for this schedule", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(saveButtonTitle) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 680)
        .background(ThemeColors.bg(for: appState.settings.theme))
        .onAppear(perform: loadInitialValues)
    }

    private var titleText: String {
        switch mode {
        case .create: return "Create Schedule"
        case .edit: return "Edit Schedule"
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .create: return "Save Schedule"
        case .edit: return "Save Changes"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.top, 4)
    }

    private func loadInitialValues() {
        switch mode {
        case .create:
            if let first = appState.agents.first {
                targetAgentId = first.id
            }
        case .edit(let auto):
            editingId = auto.id
            name = auto.name
            description = auto.description
            triggerType = auto.triggerType
            schedule = auto.cronSchedule
            watchPath = auto.watchPath ?? ""
            targetAgentId = auto.targetAgentId
            promptTemplate = auto.promptTemplate
            continueConversation = auto.continueConversation ?? false
            isEnabled = auto.isEnabled
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .create:
            let auto = Automation(
                workspaceId: appState.activeWorkspaceId,
                name: trimmed,
                description: description,
                triggerType: triggerType,
                cronSchedule: schedule,
                watchPath: watchPath.isEmpty ? nil : watchPath,
                targetAgentId: targetAgentId,
                promptTemplate: promptTemplate,
                isEnabled: isEnabled,
                continueConversation: continueConversation ? true : nil
            )
            appState.automations.append(auto)
            PersistenceManager.shared.saveAutomations(appState.automations)
            appState.showToast("Schedule '\(trimmed)' created")
        case .edit(let existing):
            guard let idx = appState.automations.firstIndex(where: { $0.id == existing.id }) else { return }
            appState.automations[idx].name = trimmed
            appState.automations[idx].description = description
            appState.automations[idx].triggerType = triggerType
            appState.automations[idx].cronSchedule = schedule
            appState.automations[idx].watchPath = watchPath.isEmpty ? nil : watchPath
            appState.automations[idx].targetAgentId = targetAgentId
            appState.automations[idx].promptTemplate = promptTemplate
            appState.automations[idx].continueConversation = continueConversation ? true : nil
            appState.automations[idx].isEnabled = isEnabled
            appState.automations[idx].updatedAt = Date()
            PersistenceManager.shared.saveAutomations(appState.automations)
            appState.showToast("Schedule '\(trimmed)' updated")
        }

        // File watches are held open against the saved list, so an edit that changes a path or
        // switches a trigger has to rebuild them or the old watch keeps firing.
        AutomationScheduler.shared.automationsChanged()
        isPresented = false
    }

    private func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            watchPath = url.path
        }
    }
}

/// Backward-compatible alias used by older call sites.
public struct NewAutomationModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    public var body: some View {
        AutomationEditorSheet(appState: appState, mode: .create, isPresented: $isPresented)
    }
}

// MARK: - History Sheet

private struct AutomationHistorySheet: View {
    @ObservedObject var appState: AppState
    let automation: Automation
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History — \(automation.name)")
                        .font(.system(size: 14, weight: .bold))
                    Text(automation.cronSchedule)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.hitTestable)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    historyRow(
                        title: "Status",
                        value: automation.isEnabled ? "Enabled" : "Paused"
                    )
                    historyRow(
                        title: "Last run",
                        value: automation.lastRunAt.map {
                            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
                        } ?? "Never"
                    )
                    historyRow(
                        title: "Last status",
                        value: automation.lastStatus ?? "—"
                    )
                    historyRow(
                        title: "Last result",
                        value: automation.lastResultSummary ?? "No result recorded yet."
                    )
                    historyRow(
                        title: "Created",
                        value: DateFormatter.localizedString(from: automation.createdAt, dateStyle: .medium, timeStyle: .short)
                    )
                    historyRow(
                        title: "Updated",
                        value: DateFormatter.localizedString(from: automation.updatedAt, dateStyle: .medium, timeStyle: .short)
                    )
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    private func historyRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemeColors.cardBg(for: appState.settings.theme))
                )
        }
    }
}
