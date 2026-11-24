import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkEngine

// Mods: what the app tells the mod host about itself, and the slash commands mods add.

extension AppState {
    /// Connect the mod host to this app and start the mods the person has turned on.
    func configureMods() {
        let host = ModHost.shared
        let env = host.env
        env.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        env.sessionId = { [weak self] in self?.currentSession?.id ?? "" }
        env.workspacePath = { [weak self] in self?.currentWorkspace.folderPath ?? NSHomeDirectory() }
        env.currentModel = { [weak self] in self?.currentModel.id ?? "" }
        env.messages = { [weak self] in self?.modMessageRows() ?? [] }
        env.transcript = { [weak self] in self?.modTranscript() ?? "" }
        env.usage = { [weak self] in self?.modUsage() ?? [:] }
        env.complete = { [weak self] prompt, system, maxTokens, timeout in
            await self?.modComplete(prompt: prompt, system: system, maxTokens: maxTokens, timeout: timeout)
        }
        env.sendMessage = { [weak self] text in self?.sendMessage(text: text) }
        env.fillPrompt = { [weak self] text in self?.composerText = text }
        env.readPrompt = { [weak self] in self?.composerText ?? "" }
        env.abortTurn = { [weak self] in self?.cancelCurrentGeneration() }
        env.agents = { [weak self] in (self?.agents ?? []).map { ["id": $0.id, "name": $0.name] } }
        env.toast = { [weak self] text in self?.showToast(text) }
        env.notify = { title, text in
            TurnCompletionNotifier.post(.init(title: title, body: text))
            return true
        }
        env.builtinToolNames = { [weak self] in (self?.tools ?? []).filter(\.isEnabled).map(\.name) }
        env.builtinCommands = { SlashCommands.builtIn.map { String($0.command.dropFirst()) } }
        env.runTool = { [weak self] name, argumentsJson in
            guard let self else { return (false, "The app is closing.") }
            let result = await ToolExecutionEngine.shared.execute(
                toolName: name, argumentsJson: argumentsJson,
                workspace: self.currentWorkspace, currentAgent: self.currentAgent
            )
            return (result.success, result.success ? result.output : (result.error ?? result.output))
        }
        env.mcpCall = { [weak self] server, tool, argumentsJson in
            guard let self else { return "The app is closing." }
            guard let config = self.settings.mcpServers.first(where: { $0.isEnabled && ($0.id == server || $0.name == server) }) else {
                return "No enabled MCP server is called “\(server)”."
            }
            return await Self.dispatchMCP(config: config, tool: tool, argumentsJson: argumentsJson, workspace: self.currentWorkspace)
        }
        host.onOpenPane = { [weak self] _ in self?.revealInspector(tab: .mods, minimumWidth: 380) }
        Task { await host.startEnabled() }
    }

    /// Parsed away from the main actor, so the arguments are never shared with it.
    nonisolated private static func dispatchMCP(config: MCPServerConfig, tool: String, argumentsJson: String, workspace: Workspace) async -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJson.utf8))) as? [String: Any] ?? [:]
        return await MCPClientManager.shared.dispatchToolCall(
            serverConfig: config, serverIdentifier: config.name, toolName: tool, arguments: arguments, workspace: workspace
        )
    }

    // MARK: - What mods see of the chat

    /// One row per message, in the shape mods know from Claude Code.
    fileprivate func modMessageRows() -> [[String: Any]] {
        guard let session = currentSession else { return [] }
        var rows: [[String: Any]] = []
        for message in session.messages where message.role == .user || message.role == .assistant {
            var row: [String: Any] = ["role": message.role == .user ? "user" : "assistant", "text": message.content]
            var uses: [[String: Any]] = []
            var results: [[String: Any]] = []
            for call in message.toolCalls {
                let claude = ModHost.claudeNames(tool: call.toolName, argumentsJson: call.argumentsJson)
                uses.append(["tool_use_id": call.id, "tool": claude.name, "input": claude.input])
                if let output = call.resultOutput ?? call.errorMessage {
                    results.append(["tool_use_id": call.id, "text": output, "isError": call.status == .error])
                }
            }
            row["toolUses"] = uses
            if !results.isEmpty { row["toolResults"] = results }
            rows.append(row)
        }
        return rows
    }

    fileprivate func modTranscript() -> String {
        guard let session = currentSession else { return "" }
        var lines: [String] = []
        for message in session.messages where message.role == .user || message.role == .assistant {
            let who = message.role == .user ? "User" : "Assistant"
            if !message.content.isEmpty { lines.append("\(who): \(message.content)") }
            for call in message.toolCalls {
                lines.append("[tool \(call.toolName) \(String(call.argumentsJson.prefix(300)))]")
                if let out = call.resultOutput { lines.append("[result \(String(out.prefix(400)))]") }
            }
        }
        return lines.joined(separator: "\n\n")
    }

    fileprivate func modUsage() -> [String: Any] {
        let session = currentSession
        let used = session?.messages.last(where: { $0.role == .assistant })?.promptTokens ?? 0
        let window = currentModel.contextWindow
        return [
            "startedAt": (session?.createdAt ?? Date()).timeIntervalSince1970 * 1000,
            "context": ["tokens": used, "window": window, "percent": window > 0 ? Int((Double(used) / Double(window) * 100).rounded()) : 0],
            "rateLimits": [Any](),
            "cost": ["usd": 0],
        ]
    }

    /// A one-shot reply from the model in use, for `$.model.complete`.
    fileprivate func modComplete(prompt: String, system: String, maxTokens: Int, timeout: TimeInterval) async -> String? {
        let provider = currentProvider, model = currentModel
        let accumulator = ToolExecutionEngine.StreamTextAccumulator()
        let message = ChatMessage(sessionId: "mod-completion", role: .user, content: prompt)
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do {
                    try await ProviderRouter.shared.stream(
                        provider: provider, model: model, systemPrompt: system, messages: [message],
                        temperature: 0.2, maxTokens: maxTokens, reasoningEffort: .off, tools: []
                    ) { chunk in
                        if !chunk.deltaText.isEmpty { accumulator.append(chunk.deltaText) }
                    }
                    return true
                } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return finished ? accumulator.text : nil
    }

    // MARK: - Slash commands

    /// `/name args` for a command a mod registered. The reply goes into the chat as a note.
    func handleModSlashCommand(_ command: String) -> Bool {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first, head.hasPrefix("/") else { return false }
        let name = String(head.dropFirst())
        guard let match = ModHost.shared.commands.first(where: { $0.name == name }) else { return false }
        let args = parts.count > 1 ? String(parts[1]) : ""
        Task { [weak self] in
            let text = await ModHost.shared.runCommand(plugin: match.plugin, name: name, args: args)
            guard let self, !text.isEmpty else { return }
            self.appendModNote(text, plugin: match.plugin)
        }
        return true
    }

    func appendModNote(_ text: String, plugin: String) {
        guard let session = currentSession, let index = sessions.firstIndex(where: { $0.id == session.id }) else { showToast(text); return }
        sessions[index].messages.append(ChatMessage(
            sessionId: session.id, role: .assistant, content: text,
            agentName: plugin, agentAvatar: "puzzlepiece.extension", agentColor: "#8B5CF6"
        ))
        PersistenceManager.shared.saveSessions(sessions)
    }

    /// Commands mods registered, for the slash menu.
    var modSlashCommands: [(command: String, description: String)] {
        ModHost.shared.commands.map { (command: "/" + $0.name, description: $0.description.isEmpty ? "From the \($0.plugin) mod" : $0.description) }
    }
}
