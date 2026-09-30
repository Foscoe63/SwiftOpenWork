import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

public struct ChatView: View {
    @State private var showingChangeReview = false
    @State private var showingSessionChangeReview = false
    @State private var turnChangeCount = 0
    /// What the empty chat offers, from the workspace's top-level files.
    @State private var starterKind: StarterSuggestions.ProjectKind = .other
    @State private var starters: [StarterSuggestions.Suggestion] = StarterSuggestions.suggestions(for: .other)
    /// The welcome screen's "Work with an agent" grid is showing instead of the starter prompts.
    @State private var agentPickerOpen = false
    /// Opened by "Start a group chat", so the picker is already unfolded.
    @State private var agentPickerStartsGroup = false
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            if let session = appState.currentSession, session.isGroup {
                GroupRosterBar(appState: appState, session: session)
            }

            // Main Chat Stream or Hero Empty State
            if let session = appState.currentSession, !session.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(session.messages) { msg in
                                MessageBubbleView(message: msg, appState: appState)
                                    .id(msg.id)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onMessageCountChanged(count: session.messages.count) {
                        scrollChatToLatest(proxy: proxy, session: session)
                    }
                    .onValueChanged(of: pendingApprovalScrollKey) {
                        scrollChatToLatest(proxy: proxy, session: session)
                    }
                }
            } else {
                emptyStateHero
            }

            // A turn that touched files gets a review affordance, so the agent's prose is not
            // the only account of what happened on disk. The session-wide count comes from the
            // transcript, so it survives past the turn the checkpoint store covers.
            if turnChangeCount > 0 || sessionChangeCount > 0 {
                changeReviewBar
            }

            // Composer Dock
            VStack(spacing: 8) {
                PlanModeBanner(appState: appState)
                SessionTodosBar(appState: appState)
                ComposerView(appState: appState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingChangeReview) {
            TurnChangeReviewView(
                appState: appState,
                root: appState.currentWorkspace.folderPath,
                onRevert: { Task { await refreshTurnChangeCount() } }
            )
            .frame(minWidth: 780, minHeight: 520)
        }
        .sheet(isPresented: $showingSessionChangeReview) {
            SessionChangeReviewView(
                appState: appState,
                root: appState.currentWorkspace.folderPath
            )
            .frame(minWidth: 780, minHeight: 520)
        }
        .sheet(item: $appState.pendingRestore) { pending in
            RestoreFilesSheet(appState: appState, pending: pending)
        }
        .onValueChanged(of: appState.presentTurnChangeReview) {
            if appState.presentTurnChangeReview {
                showingChangeReview = true
                appState.presentTurnChangeReview = false
            }
        }
        .task(id: appState.currentSessionId) {
            appState.refreshRestorePoints()
        }
        .task(id: appState.isGenerating) {
            await refreshTurnChangeCount()
            while !Task.isCancelled, appState.isGenerating {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshTurnChangeCount()
            }
            await refreshTurnChangeCount()
        }
    }

    /// Footer summarising this turn's file changes, with a way into the diff review.
    private var changeReviewBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 11))
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
            Text(turnChangeCount > 0
                 ? "\(turnChangeCount) file\(turnChangeCount == 1 ? "" : "s") changed this turn"
                 : "\(sessionChangeCount) file\(sessionChangeCount == 1 ? "" : "s") changed this session")
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            Spacer()
            if turnChangeCount > 0 {
                Button("Review turn") { showingChangeReview = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if appState.isGenerating, turnChangeCount > 0 {
                Text("live")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
            if sessionChangeCount > 0 {
                Button("Review session") { showingSessionChangeReview = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ThemeColors.border(for: appState.settings.theme))
                .frame(height: 1)
        }
    }

    /// Read from the transcript rather than the checkpoint store, which only covers this turn.
    private var sessionChangeCount: Int {
        SessionChangeSummary.changedFiles(
            in: appState.currentSession?.messages ?? [],
            workspaceRoot: appState.currentWorkspace.folderPath
        ).count
    }

    private func refreshTurnChangeCount() async {
        let count = await FileCheckpointStore.shared.changes().count
        await MainActor.run { turnChangeCount = count }
    }

    /// Changes when the latest message gains/loses a pending Approve/Reject — scroll so it stays on screen.
    private var pendingApprovalScrollKey: String {
        guard let last = appState.currentSession?.messages.last else { return "" }
        let pending = last.toolCalls
            .filter { $0.status == .waitingApproval || $0.status == .pendingApproval }
            .map(\.id)
            .sorted()
        return pending.joined(separator: ",")
    }

    private func scrollChatToLatest(proxy: ScrollViewProxy, session: Session) {
        guard let last = session.messages.last else { return }
        let hasPending = last.toolCalls.contains {
            $0.status == .waitingApproval || $0.status == .pendingApproval
        }
        withAnimation {
            if hasPending {
                proxy.scrollTo("approval-\(last.id)", anchor: .bottom)
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            // Title & Status
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.currentSession?.title ?? "New Session")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isGenerating ? Color.orange : (appState.backgroundRuns.isEmpty ? Color.green : Color.blue))
                        .frame(width: 6, height: 6)
                    Text(BackgroundRun.statusLine(chatIsGenerating: appState.isGenerating, runs: appState.backgroundRuns))
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .lineLimit(1)
                        .help(appState.backgroundRuns.map(\.title).joined(separator: "\n"))
                }
            }

            // Session workspace — synced with sidebar "Core Workspaces & Research"
            WorkspaceSwitcherMenu(
                appState: appState,
                showsManagementActions: true,
                onSelectWorkspace: { id in
                    appState.assignCurrentSessionWorkspace(to: id)
                }
            ) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: appState.currentWorkspace.color))
                        .frame(width: 7, height: 7)

                    Image(systemName: appState.currentWorkspace.icon)
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

                    Text(appState.currentWorkspace.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ThemeColors.sidebarBg(for: appState.settings.theme))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.8), lineWidth: 1)
                )
            }
            .help("Workspace for this session (synced with sidebar)")

            // Quick Model Selector in Header (searchable)
            ModelPickerButton(appState: appState, style: .header)

            Spacer()

            // Header Toolbar Actions
            HStack(spacing: 6) {
                // Export Session Menu
                Menu {
                    Button("Export as Markdown (.md)") {
                        appState.exportCurrentSession(as: .markdown)
                    }
                    Button("Export as JSON (.json)") {
                        appState.exportCurrentSession(as: .json)
                    }
                    Button("Export as HTML / Printable Report") {
                        appState.exportCurrentSession(as: .html)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
                .help("Export Chat Session")

                // Clear Session
                Button {
                    appState.sendMessage(text: "/clear")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.hitTestable)
                .help("Clear Session Messages")

                // Open Interactive Terminal Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.inspectorTab = .terminal
                        appState.isInspectorOpen = true
                    }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundColor(appState.isInspectorOpen && appState.inspectorTab == .terminal ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.hitTestable)
                .help("Open Workspace Terminal")

                // Toggle Side Inspector
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.isInspectorOpen.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13))
                        .foregroundColor(appState.isInspectorOpen ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.hitTestable)
                .help("Toggle Sub-Agent Inspector Panel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Empty State Hero
    private var emptyStateHero: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 48))
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

            VStack(spacing: 6) {
                Text("SwiftOpenWork AI Agent Workspace")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Text(heroSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .multilineTextAlignment(.center)
            }

            if agentPickerOpen {
                // 13 agents and an unfolded picker are taller than a small window; the logo and
                // title stay put and this part scrolls.
                ScrollView {
                    AgentChoiceGrid(appState: appState, opensGroupPicker: agentPickerStartsGroup) {
                        agentPickerOpen = false
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            } else {
                agentEntryPoints
            }

            // Quick Starter Prompt Cards (Centered with clean constrained responsive grid)
            if !agentPickerOpen {
            VStack {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 12)
                ], spacing: 12) {
                    ForEach(starters) { starter in
                        starterCard(title: starter.title, subtitle: starter.subtitle, icon: starter.icon, prompt: starter.prompt)
                    }
                }
                .frame(maxWidth: 880)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: appState.currentWorkspace.folderPath) {
            let folder = appState.currentWorkspace.folderPath
            let kind = await Task.detached { StarterSuggestions.kind(ofFolder: folder) }.value
            starterKind = kind
            starters = StarterSuggestions.suggestions(for: kind)
        }
    }

    /// What the empty chat says it is for: the room when it is a group chat.
    private var heroSubtitle: String {
        let workspace = appState.currentWorkspace.name
        if let session = appState.currentSession, session.isGroup {
            let names = appState.participants(of: session).map(\.name).joined(separator: ", ")
            return "Group chat with \(names) in \(workspace)\nName one with @ to have it act; otherwise everyone answers in prose."
        }
        return starterKind == .empty
            ? "What should we build in \(workspace)?"
            : "Working in \(workspace)"
    }

    /// Ways into a specific agent, or several: the same two doors Radiant's welcome screen has.
    private var agentEntryPoints: some View {
        HStack(spacing: 10) {
            entryPill(title: "Work with an agent", icon: "person.crop.circle.badge.checkmark") {
                agentPickerStartsGroup = false
                agentPickerOpen = true
            }
            if appState.agents.count >= 2 {
                entryPill(title: "Start a group chat", icon: "person.2") {
                    agentPickerStartsGroup = true
                    agentPickerOpen = true
                }
            }
        }
    }

    private func entryPill(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .overlay(Capsule().stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.hitTestable)
    }

    private func starterCard(title: String, subtitle: String, icon: String, prompt: String) -> some View {
        Button {
            appState.sendMessage(text: prompt)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 95, alignment: .topLeading)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
