import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

public struct AgentsView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddAgent = false
    @State private var showingTemplates = false
    /// Set by the template picker; opened in the editor once the picker has finished dismissing,
    /// since one sheet cannot present another while it is still on screen.
    @State private var pendingTemplateAgent: Agent? = nil
    @State private var editingAgent: Agent? = nil
    @State private var selectedTab: String = "list" // list, collaboration

    // Collaboration room state
    @State private var collaborationGoal: String = "Architect and review a high-throughput Swift async actor pipeline."
    @State private var isCollaborating: Bool = false
    @State private var collaborationLog: [String] = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Mode Selector: Agents Inventory vs Multi-Agent Collaboration Room.
            // `enableAgentCollaborationRoom` is what this segment is for; it was stored, had a
            // toggle in Advanced Settings, and gated nothing.
            if appState.settings.enableAgentCollaborationRoom {
                Picker("", selection: $selectedTab) {
                    Text("AI Agents & Sub-Agents").tag("list")
                    Text("Multi-Agent Collaboration Room").tag("collaboration")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if selectedTab == "list" || !appState.settings.enableAgentCollaborationRoom {
                agentsListContent
            } else {
                collaborationRoomContent
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddAgent) {
            // Seeded from Settings' defaults. They existed but nothing read them, so a user who
            // set a default temperature got 0.7 anyway and had no way to tell.
            agentEditModal(agent: Agent(
                name: "New Agent",
                role: "Specialist",
                temperature: appState.settings.defaultTemperature,
                maxTokens: appState.settings.defaultMaxTokens,
                reasoningEffort: appState.settings.defaultReasoningEffort
            ))
        }
        .sheet(isPresented: $showingTemplates, onDismiss: {
            if let agent = pendingTemplateAgent {
                pendingTemplateAgent = nil
                editingAgent = agent
            }
        }) {
            AgentTemplatePicker(theme: appState.settings.theme, accent: appState.settings.accentColor) { template in
                pendingTemplateAgent = template.makeAgent(
                    temperature: appState.settings.defaultTemperature,
                    maxTokens: appState.settings.defaultMaxTokens,
                    reasoningEffort: appState.settings.defaultReasoningEffort
                )
                showingTemplates = false
            }
        }
        .sheet(item: $editingAgent) { agent in
            agentEditModal(agent: agent)
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Agents Hub")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Text("Manage autonomous agents, sub-agent hierarchies, and communication permissions")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            Button {
                showingTemplates = true
            } label: {
                Label("From Template", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            Button {
                showingAddAgent = true
            } label: {
                Label("Create Agent", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeColors.accent(for: appState.settings.accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Agents List Content
    private var agentsListContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 14)], spacing: 14) {
                ForEach(appState.agents) { agent in
                    agentCard(agent: agent)
                }
            }
            .padding(16)
        }
    }

    private func agentCard(agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: agent.avatar)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color(hex: agent.color))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        if agent.isLeadAgent {
                            Text("LEAD")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.2))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                .cornerRadius(4)
                        }
                    }

                    Text(agent.role)
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Spacer()

                Menu {
                    Button("Set as Active Agent") {
                        appState.selectedAgentId = agent.id
                        appState.showToast("\(agent.name) is now active")
                    }
                    Button("Start New Chat with Agent") {
                        appState.createNewSession(agentId: agent.id)
                    }
                    Button("Edit Agent...") {
                        editingAgent = agent
                    }
                    if !agent.isBuiltIn {
                        Divider()
                        Button("Delete Agent", role: .destructive) {
                            appState.deleteAgent(agent)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .menuStyle(.borderlessButton)
            }

            Text(agent.description)
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                .lineLimit(2)

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Sub-Agents & Capabilities row
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.circle.fill")
                        .font(.system(size: 10))
                    Text(agent.canSpawnSubAgents ? "Can spawn sub-agents (\(agent.subAgentIds.count))" : "Sub-agent only")
                        .font(.system(size: 10))
                }
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                    Text("\(agent.allowedToolIds.count) tools")
                        .font(.system(size: 10))
                }
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(agent.id == appState.selectedAgentId ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Multi-Agent Collaboration Room
    private var collaborationRoomContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Collaborative Problem Solving")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                HStack {
                    TextField("Enter high-level objective for agent collaboration...", text: $collaborationGoal)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        startCollaboration()
                    } label: {
                        HStack(spacing: 4) {
                            if isCollaborating {
                                ProgressView().scaleEffect(0.5)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isCollaborating ? "Collaborating..." : "Start Collaboration")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ThemeColors.accent(for: appState.settings.accentColor))
                    .disabled(isCollaborating || collaborationGoal.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Timeline & Message Output
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if collaborationLog.isEmpty {
                        Text("Start a plan → draft → review roundtable with the lead agent's team. Text only; nothing is written to disk.")
                            .font(.system(size: 12))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(collaborationLog.enumerated()), id: \.offset) { _, log in
                            Text(LocalizedStringKey(log))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ThemeColors.cardBg(for: appState.settings.theme))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// A plan → draft → review roundtable with the lead agent's own team. Text only.
    ///
    /// This used to fill in for the agents. When a model returned nothing it showed a hardcoded
    /// plan, a hardcoded `actor PipelineManager`, and a review reading "✅ Verified: Strict actor
    /// isolation preserved. No race conditions detected. Ready for merge." — then "Team Consensus
    /// Reached. Objective complete." whatever had happened. And a model that did answer could
    /// still read as empty: chunks were applied on later main-actor hops, so the text was read
    /// before they landed and the fabricated fallback was shown instead of the real reply. It also
    /// picked agents by hardcoded id, falling back to whichever agent happened to be first.
    ///
    /// Now each step shows what that agent actually said, a failure stops the roundtable and says
    /// why, and the team comes from the lead agent's configuration.
    private func startCollaboration() {
        isCollaborating = true
        collaborationLog.removeAll()

        let goal = collaborationGoal
        Task { @MainActor in
            defer { isCollaborating = false }

            let lead = appState.currentAgent.subAgentIds.isEmpty
                ? (appState.agents.first(where: { $0.isLeadAgent && !$0.subAgentIds.isEmpty }) ?? appState.currentAgent)
                : appState.currentAgent
            let team = lead.subAgentIds.compactMap { id in appState.agents.first { $0.id == id } }
            func matches(_ agent: Agent, _ words: [String]) -> Bool {
                let text = (agent.role + " " + agent.name).lowercased()
                return words.contains { text.contains($0) }
            }
            guard let implementer = team.first(where: { matches($0, ["engineer", "coder", "develop"]) }) ?? team.first else {
                collaborationLog.append("❌ \(lead.name) has no team. Add sub-agents to it in AI Agents, then start again.")
                return
            }
            let reviewer = team.first { $0.id != implementer.id && matches($0, ["review", "critic", "quality"]) }

            collaborationLog.append("🚀 Roundtable for: \"\(goal)\" — \(lead.name) plans, \(implementer.name) drafts\(reviewer.map { ", \($0.name) reviews" } ?? ""). Text only: nothing is written to disk.")

            let parent = AgentRunContext.Frame(provider: appState.currentProvider, model: appState.currentModel, depth: 0)

            @MainActor func step(_ agent: Agent, _ prompt: String) async -> String? {
                guard let choice = AgentRunContext.subAgentModel(
                    for: agent, parent: parent, providers: appState.providers, settings: appState.settings
                ) else {
                    collaborationLog.append("❌ No usable model for \(agent.name).")
                    return nil
                }
                if let note = choice.note { collaborationLog.append("ℹ️ \(note)") }
                // Appended synchronously from the stream callback, so the full reply is there the
                // moment the stream returns.
                let box = ConcurrentTextBox()
                do {
                    try await ProviderRouter.shared.stream(
                        provider: choice.provider,
                        model: choice.model,
                        systemPrompt: agent.systemPrompt,
                        messages: [ChatMessage(sessionId: "collab", role: .user, content: prompt)],
                        temperature: agent.temperature,
                        maxTokens: max(agent.maxTokens, 1024),
                        reasoningEffort: .low
                    ) { chunk in
                        if !chunk.deltaText.isEmpty { box.append(chunk.deltaText) }
                    }
                } catch {
                    collaborationLog.append("❌ \(agent.name) failed: \(error.localizedDescription)")
                    return nil
                }
                let text = AssistantContentSanitizer.splitThinking(from: box.text).visible
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    collaborationLog.append("❌ \(agent.name) returned nothing. The roundtable stopped here.")
                    return nil
                }
                return text
            }

            collaborationLog.append("🧠 [\(lead.name)] Planning…")
            guard let plan = await step(lead, "Write a short, structured implementation plan (at most five points) for: \(goal)") else { return }
            collaborationLog.append("📋 [\(lead.name) — plan]\n\(plan)")

            collaborationLog.append("💻 [\(implementer.name)] Drafting…")
            guard let draft = await step(implementer, "Objective: \(goal)\n\nDraft the core implementation for this plan:\n\(plan)") else { return }
            collaborationLog.append("💻 [\(implementer.name) — draft]\n\(draft)")

            if let reviewer {
                collaborationLog.append("🔍 [\(reviewer.name)] Reviewing…")
                guard let review = await step(reviewer, "Objective: \(goal)\n\nReview this draft against the plan. List concrete problems first; do not approve what you have not checked.\n\nPlan:\n\(plan)\n\nDraft:\n\(draft)") else { return }
                collaborationLog.append("🔍 [\(reviewer.name) — review]\n\(review)")
            } else {
                collaborationLog.append("ℹ️ No reviewer on \(lead.name)'s team, so the draft was not reviewed.")
            }

            collaborationLog.append("Done. This was a text roundtable — no files were changed. To have agents do the work, give the objective to \(lead.name) in Chat; it delegates to its team with real tools.")
        }
    }

    // MARK: - Agent Edit Modal
    private func agentEditModal(agent: Agent) -> some View {
        AgentEditModalView(agent: agent, appState: appState) { updated in
            appState.saveAgent(updated)
            editingAgent = nil
            showingAddAgent = false
        } onCancel: {
            editingAgent = nil
            showingAddAgent = false
        }
    }
}

public struct AgentEditModalView: View {
    @State var draft: Agent
    @ObservedObject var appState: AppState
    var onSave: (Agent) -> Void
    var onCancel: () -> Void

    private let availableAvatars = [
        "sparkles", "brain.head.profile", "chevron.left.forwardslash.chevron.right",
        "checkmark.shield.fill", "square.3.layers.3d.down.right", "terminal.fill",
        "wrench.and.screwdriver.fill", "cpu", "globe", "folder.badge.gearshape"
    ]

    private let availableColors = [
        "#8B5CF6", "#3B82F6", "#10B981", "#F59E0B", "#EC4899", "#06B6D4", "#EF4444"
    ]

    public init(agent: Agent, appState: AppState, onSave: @escaping (Agent) -> Void, onCancel: @escaping () -> Void) {
        self._draft = State(initialValue: agent)
        self.appState = appState
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: draft.avatar)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(hex: draft.color))
                        .clipShape(Circle())

                    Text(draft.name.isEmpty ? "Create Agent" : "Edit \(draft.name)")
                        .font(.system(size: 14, weight: .bold))
                }
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Identity
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Identity & Appearance")
                            .font(.system(size: 12, weight: .bold))

                        HStack {
                            Text("Avatar Icon:")
                                .font(.system(size: 11.5))
                            ForEach(availableAvatars, id: \.self) { av in
                                Button {
                                    draft.avatar = av
                                } label: {
                                    Image(systemName: av)
                                        .font(.system(size: 12))
                                        .padding(5)
                                        .background(draft.avatar == av ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.3) : Color.clear)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }

                        HStack {
                            Text("Color Theme:")
                                .font(.system(size: 11.5))
                            ForEach(availableColors, id: \.self) { col in
                                Button {
                                    draft.color = col
                                } label: {
                                    Circle()
                                        .fill(Color(hex: col))
                                        .frame(width: 16, height: 16)
                                        .overlay(
                                            Circle().stroke(Color.white, lineWidth: draft.color == col ? 2 : 0)
                                        )
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }

                        TextField("Agent Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("Role / Title", text: $draft.role)
                            .textFieldStyle(.roundedBorder)
                        TextField("Description", text: $draft.description)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Instructions & Persona
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Instructions & Persona")
                            .font(.system(size: 12, weight: .bold))
                        TextEditor(text: $draft.systemPrompt)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 110)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    }

                    Divider()

                    // Sub-Agents & Hierarchy
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sub-Agent Permissions & Hierarchy")
                            .font(.system(size: 12, weight: .bold))

                        Toggle("Can Spawn Child Sub-Agents", isOn: $draft.canSpawnSubAgents)
                        Toggle("Can Communicate with Other Agents", isOn: $draft.canCommunicateWithOthers)
                        Toggle("Auto-Delegate Complex Tasks", isOn: $draft.autoDelegate)
                        Stepper("Max Sub-Agent Nesting Depth: \(draft.maxSubAgentDepth)", value: $draft.maxSubAgentDepth, in: 1...5)
                    }

                    Divider()

                    // Allowed Tools
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Allowed Tools & Capabilities")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            Button("Select All") {
                                for t in appState.tools {
                                    if !draft.allowedToolIds.contains(t.id) {
                                        draft.allowedToolIds.append(t.id)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }

                        ForEach(appState.tools) { tool in
                            let isIncluded = draft.allowedToolIds.contains(tool.id) || draft.allowedToolIds.contains(tool.name)
                            Toggle(isOn: Binding(
                                get: { isIncluded },
                                set: { val in
                                    if val {
                                        if !draft.allowedToolIds.contains(tool.id) {
                                            draft.allowedToolIds.append(tool.id)
                                        }
                                    } else {
                                        draft.allowedToolIds.removeAll(where: { $0 == tool.id || $0 == tool.name })
                                    }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Image(systemName: tool.category.icon)
                                        .font(.system(size: 11))
                                        .foregroundColor(tool.category == .mcp ? ThemeColors.accent(for: appState.settings.accentColor) : .primary)
                                    Text(tool.displayName)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text("(\(tool.name))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    // LLM Parameters
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LLM Model & Parameters")
                            .font(.system(size: 12, weight: .bold))

                        HStack {
                            Text("Model Provider:")
                                .font(.system(size: 11.5))
                            Picker("", selection: $draft.providerId) {
                                ForEach(appState.providers.filter { $0.isEnabled }) { prov in
                                    Text(prov.name).tag(prov.id)
                                }
                            }
                        }

                        HStack {
                            Text("Temperature (\(String(format: "%.2f", draft.temperature)))")
                                .font(.system(size: 11.5))
                            Slider(value: $draft.temperature, in: 0.0...1.0, step: 0.05)
                        }

                        Stepper("Max Output Tokens: \(draft.maxTokens)", value: $draft.maxTokens, in: 512...32768, step: 512)

                        // The turn uses `agent.reasoningEffort`, and this was the only one of the
                        // three sampling fields with no control on an existing agent: Settings
                        // seeds it into new agents only, so an agent created before you changed
                        // your mind could never be adjusted.
                        HStack {
                            Text("Reasoning Effort")
                                .font(.system(size: 11.5))
                            Picker("", selection: $draft.reasoningEffort) {
                                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                    Text(effort.displayName).tag(effort)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Save Agent") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 540, height: 620)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
