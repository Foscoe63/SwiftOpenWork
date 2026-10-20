import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Add coding agents that run as their own programs — Claude Code, Codex, Gemini CLI, OpenCode,
/// Goose — and talk to this app over the Agent Client Protocol. Each becomes an agent you can pick
/// in the composer, with this app's approvals, undo, diff review and audit log around it.
public struct ExternalAgentsCard: View {
    @ObservedObject var appState: AppState
    @State private var customName = ""
    @State private var customCommand = ""
    @State private var customEnv = ""
    @State private var message: String?

    /// `KEY=value` pairs separated by spaces; a leading `~` in a value is the home folder.
    static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for word in text.split(separator: " ") {
            guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { continue }
            let key = String(word[..<eq])
            let value = String(word[word.index(after: eq)...])
            env[key] = (value as NSString).expandingTildeInPath
        }
        return env
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    private var external: [Agent] { appState.agents.filter { $0.externalAgent != nil } }

    public var body: some View {
        SettingsCard(
            title: "External Agents (ACP)",
            description: "Use agents you already run — Claude Code, Codex, Gemini CLI, OpenCode, Goose — inside this app. They keep their own models and sign-ins; permissions, file access, undo and the audit log stay here. They must be installed already.",
            icon: "person.2.badge.gearshape"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ACPMapping.presets) { preset in
                    let installed = ExecutableLocator().executable(named: preset.config.command) != nil
                    let added = external.contains { $0.externalAgent == preset.config }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name).font(.system(size: 12, weight: .semibold))
                            Text(preset.detail + (installed ? "" : " — `\(preset.config.command)` not found on PATH"))
                                .font(.system(size: 10.5)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if added {
                            Label("Added", systemImage: "checkmark").font(.system(size: 11)).foregroundColor(.secondary)
                        } else {
                            Button("Add") { add(name: preset.name, config: preset.config, detail: preset.detail) }
                                .controlSize(.small).disabled(!installed)
                        }
                    }
                }

                Divider()
                Text("Any other ACP agent").font(.system(size: 12, weight: .semibold))
                HStack {
                    TextField("Name", text: $customName).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("Command, e.g. my-agent --acp", text: $customCommand).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let words = customCommand.split(separator: " ").map(String.init)
                        guard let command = words.first, !customName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        add(name: customName, config: ExternalAgentConfig(command: command, args: Array(words.dropFirst()), env: Self.parseEnv(customEnv)), detail: "Custom ACP agent")
                        customName = ""; customCommand = ""; customEnv = ""
                    }
                    .controlSize(.small)
                }
                TextField("Environment (optional), e.g. CLAUDE_CONFIG_DIR=~/.claude-work", text: $customEnv)
                    .textFieldStyle(.roundedBorder)

                if !external.isEmpty {
                    Divider()
                    ForEach(external) { agent in
                        HStack {
                            Image(systemName: agent.avatar)
                            Text(agent.name).font(.system(size: 12, weight: .medium))
                            Text(agent.externalAgent?.displayLine ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            if let config = agent.externalAgent {
                                modelPicker(for: agent, config: config)
                            }
                            Button("Remove", role: .destructive) { appState.deleteAgent(agent) }.controlSize(.small)
                        }
                    }
                }
                if let message { Text(message).font(.system(size: 11)).foregroundColor(.secondary) }
                Text("An external agent's own tools run in its process: your hooks and the shell sandbox can't see them. What it asks permission for, and every file it reads or writes through this app, is covered by your rules, approvals and undo.")
                    .font(.system(size: 10.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let claudeModels: [(label: String, value: String)] = [
        ("Sonnet", "sonnet"), ("Opus", "opus"), ("Haiku", "haiku"),
    ]

    /// Choices for an agent's model: Claude's aliases, plus whatever the agent has told us it offers
    /// (known after its first session), plus the current setting so it is always selectable.
    private func modelChoices(for config: ExternalAgentConfig, current: String) -> [(label: String, value: String)] {
        var choices: [(label: String, value: String)] = config.isClaudeCode ? Self.claudeModels : []
        for model in ACPModelCatalog.models(for: config) where !choices.contains(where: { $0.value == model.id }) {
            choices.append((model.name, model.id))
        }
        choices.append(("Agent's default", "default"))
        if !choices.contains(where: { $0.value == current }) { choices.insert((current, current), at: 0) }
        return choices
    }

    private func modelPicker(for agent: Agent, config: ExternalAgentConfig) -> some View {
        let current = config.model ?? (config.isClaudeCode ? "sonnet" : "default")
        return HStack(spacing: 6) {
            Picker("Model", selection: Binding(
                get: { current },
                set: { value in
                    var updated = agent
                    updated.externalAgent?.model = value
                    appState.saveAgent(updated)
                }
            )) {
                ForEach(modelChoices(for: config, current: current), id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden().controlSize(.small).frame(width: 150)
            .help("The model this agent runs on. Pick a lighter one to use your allowance more slowly. Models are listed once the agent has started a session; applied at the start of each new session.")
            if config.isClaudeCode {
                Toggle("Lean", isOn: Binding(
                    get: { config.effectiveLeanContext },
                    set: { value in
                        var updated = agent
                        updated.externalAgent?.leanContext = value
                        appState.saveAgent(updated)
                    }
                ))
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Lean context: leave out your global MCP servers, skills and plugins, which are re-sent on every step. The project's own settings still apply. Takes effect on the next new session.")
            }
        }
    }

    private func add(name: String, config: ExternalAgentConfig, detail: String) {
        var agent = Agent(
            name: name, description: detail, avatar: "terminal", color: "#0EA5E9", role: "External coding agent",
            systemPrompt: "", tags: ["External"], externalAgent: config
        )
        agent.canSpawnSubAgents = false
        appState.saveAgent(agent)
        message = "\(name) added. Pick it from the agent menu in the composer."
    }
}

/// Token use for each Claude Code login the External Agents list points at, so the second
/// account can be told apart from the first. Read from Claude Code's own transcripts.
public struct ClaudeUsageCard: View {
    @ObservedObject var appState: AppState
    @State private var usages: [ClaudeCodeUsage] = []
    @State private var loading = false

    public init(appState: AppState) {
        self.appState = appState
    }

    /// One entry per config folder, with the names of the agents that use it.
    private var folders: [(dir: String, agents: [String])] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        for agent in appState.agents {
            guard let config = agent.externalAgent, let dir = ClaudeCodeUsage.configDir(for: config) else { continue }
            if names[dir] == nil { order.append(dir) }
            names[dir, default: []].append(agent.name)
        }
        return order.map { ($0, names[$0] ?? []) }
    }

    public var body: some View {
        SettingsCard(
            title: "Claude Code Usage",
            description: "Tokens used by each Claude Code sign-in, read from its transcripts on this Mac. Your plan's remaining allowance is shown by /usage inside Claude Code. In a chat, /usage shows this chat too.",
            icon: "chart.bar"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if folders.isEmpty {
                    Text("Add Claude Code under External Agents to see its usage here.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(folders, id: \.dir) { folder in
                    let usage = usages.first { $0.configDir == folder.dir }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.agents.joined(separator: ", ")).font(.system(size: 12, weight: .semibold))
                        Text("\(usage?.accountEmail ?? "not signed in") · \(folder.dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                            .font(.system(size: 10.5)).foregroundColor(.secondary)
                        if let usage {
                            row("Last 5 hours", usage.last5Hours)
                            row("Today", usage.today)
                            row("Last 7 days", usage.last7Days)
                        } else {
                            Text(loading ? "Reading…" : "—").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
                Button(loading ? "Reading…" : "Refresh") { Task { await refresh() } }
                    .controlSize(.small).disabled(loading)
            }
        }
        .task { await refresh() }
    }

    private func row(_ label: String, _ tokens: ClaudeCodeUsage.Tokens) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 90, alignment: .leading)
            Text(ClaudeCodeUsage.line(tokens)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    private func refresh() async {
        let dirs = folders.map(\.dir)
        loading = true
        usages = await Task.detached { dirs.map { ClaudeCodeUsage.scan(configDir: $0) } }.value
        loading = false
    }
}
