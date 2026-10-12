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
    @State private var message: String?

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
                        add(name: customName, config: ExternalAgentConfig(command: command, args: Array(words.dropFirst())), detail: "Custom ACP agent")
                        customName = ""; customCommand = ""
                    }
                    .controlSize(.small)
                }

                if !external.isEmpty {
                    Divider()
                    ForEach(external) { agent in
                        HStack {
                            Image(systemName: agent.avatar)
                            Text(agent.name).font(.system(size: 12, weight: .medium))
                            Text(agent.externalAgent?.displayLine ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
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
