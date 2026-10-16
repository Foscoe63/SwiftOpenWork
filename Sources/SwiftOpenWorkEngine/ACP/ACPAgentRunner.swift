import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// Pure translation between ACP's vocabulary and the app's own: what a `session/update` means for
/// the chat, and what a permission request is asking about.
public enum ACPMapping {

    public static func status(_ raw: String?) -> ToolCallStatus {
        switch raw {
        case "completed": return .success
        case "failed": return .error
        case "pending", "in_progress": return .running
        default: return .running
        }
    }

    /// The built-in tool a call corresponds to, so permission rules, audit and approval wording
    /// treat an external agent's `execute` like our own `terminal_command`.
    public static func equivalentTool(kind: String?, rawInput: [String: Any], locations: [String]) -> (tool: String, arguments: [String: Any])? {
        switch kind {
        case "execute":
            guard let command = (rawInput["command"] as? String) ?? (rawInput["cmd"] as? String) else { return nil }
            return ("terminal_command", ["command": command])
        case "edit":
            guard let path = (rawInput["file_path"] as? String) ?? (rawInput["path"] as? String) ?? locations.first else { return nil }
            return ("file_write", ["path": path])
        case "delete":
            guard let path = (rawInput["path"] as? String) ?? locations.first else { return nil }
            return ("file_delete", ["path": path])
        case "move":
            guard let path = (rawInput["source"] as? String) ?? (rawInput["path"] as? String) ?? locations.first else { return nil }
            return ("file_move", ["source": path])
        case "fetch":
            guard let url = (rawInput["url"] as? String) else { return nil }
            return ("fetch_url", ["url": url])
        default:
            return nil
        }
    }

    /// Which option answers an approval. A person's yes is "allow once"; a no is "reject once".
    public static func optionId(for approved: Bool, in options: [[String: Any]]) -> String? {
        let wanted = approved ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in wanted {
            if let match = options.first(where: { ($0["kind"] as? String) == kind }), let id = match["optionId"] as? String { return id }
        }
        return nil
    }

    /// Plain text of a content block (text, resource link, embedded text resource).
    public static func text(of block: [String: Any]?) -> String {
        guard let block else { return "" }
        switch block["type"] as? String {
        case "text": return block["text"] as? String ?? ""
        case "resource_link": return "[\((block["name"] as? String) ?? (block["uri"] as? String) ?? "link")]"
        case "resource": return ((block["resource"] as? [String: Any])?["text"] as? String) ?? ""
        case "image": return "[image]"
        default: return ""
        }
    }

    /// Known ACP agents, as starting points. Command lines drift between releases; they are
    /// editable after they are added.
    public struct Preset: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var detail: String
        public var config: ExternalAgentConfig
    }

    public static let presets: [Preset] = [
        Preset(name: "Claude Code", detail: "Anthropic's agent, through the Zed ACP adapter (needs Node)",
               config: ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/claude-code-acp"])),
        Preset(name: "Claude Code (second account)",
               detail: "A separate Claude sign-in kept in ~/.claude-desktop. Run `CLAUDE_CONFIG_DIR=~/.claude-desktop claude`, then /login, once",
               config: ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/claude-code-acp"],
                                           env: ["CLAUDE_CONFIG_DIR": NSHomeDirectory() + "/.claude-desktop"])),
        Preset(name: "Codex", detail: "OpenAI's agent, through the Zed ACP adapter (needs Node)",
               config: ExternalAgentConfig(command: "npx", args: ["-y", "@zed-industries/codex-acp"])),
        Preset(name: "Gemini CLI", detail: "Google's agent (`gemini --experimental-acp`)",
               config: ExternalAgentConfig(command: "gemini", args: ["--experimental-acp"])),
        Preset(name: "OpenCode", detail: "The open-source agent (`opencode acp`)",
               config: ExternalAgentConfig(command: "opencode", args: ["acp"])),
        Preset(name: "Goose", detail: "Block's agent (`goose acp`)",
               config: ExternalAgentConfig(command: "goose", args: ["acp"])),
    ]
}

/// Keeps one agent process per chat and agent, so a conversation with an external agent is one ACP
/// session across turns, and stops it after it has been idle for a while.
actor ACPSessionPool {
    static let shared = ACPSessionPool()

    struct Entry {
        var connection: ACPConnection
        var sessionId: String
        var lastUsed: Date
        var supportsImages: Bool
    }

    private var entries: [String: Entry] = [:]
    private var reaper: Task<Void, Never>?
    static let idleLimit: TimeInterval = 20 * 60

    func entry(for key: String) -> Entry? {
        guard var entry = entries[key], entry.connection.isRunning else { entries[key] = nil; return nil }
        entry.lastUsed = Date()
        entries[key] = entry
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        entries[key]?.connection.stop()
        entries[key] = entry
        if reaper == nil {
            reaper = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    await self?.reapIdle()
                }
            }
        }
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)?.connection.stop()
    }

    func stopAll() {
        entries.values.forEach { $0.connection.stop() }
        entries.removeAll()
    }

    private func reapIdle() {
        let cutoff = Date().addingTimeInterval(-Self.idleLimit)
        for (key, entry) in entries where entry.lastUsed < cutoff { remove(key) }
    }
}

/// Runs a turn on an external agent over ACP and shows it in the chat the way the app's own turns
/// are shown: streamed text, reasoning, tool cards with their diffs, a todo list, approvals.
///
/// What this app still owns: **permissions** (the agent asks, our rules and approval level answer,
/// and every decision lands in the audit log), **file access** (reads and writes the agent
/// performs through us pass the workspace boundary and the undo checkpoints), and **the stop
/// button**. What it does not: the agent's own tools run in its own process, so PreToolUse hooks
/// and the shell sandbox cannot see them — only what it asks permission for reaches us.
@MainActor
public enum ACPAgentRunner {

    public static let clientName = "SwiftOpenWork"

    /// The agent's own session id for this chat, once a turn has started one.
    public static func agentSessionId(chat: Session, agent: Agent) async -> String? {
        await ACPSessionPool.shared.entry(for: "\(chat.id)|\(agent.id)")?.sessionId
    }

    public static func run(
        session: Session,
        agent: Agent,
        config: ExternalAgentConfig,
        workspace: Workspace,
        onMessageUpdated: @escaping (ChatMessage) -> Void,
        onSessionTodosUpdated: (([SessionTodoItem]) -> Void)?
    ) async {
        let message = ChatMessage(
            sessionId: session.id, role: .assistant, content: "", agentId: agent.id, agentName: agent.name,
            agentAvatar: agent.avatar, agentColor: agent.color, modelId: agent.name, providerId: "acp", isStreaming: true
        )
        onMessageUpdated(message)
        let accumulator = AgentStreamAccumulator(initialMessage: message, onUpdate: onMessageUpdated)
        defer { if accumulator.message.isStreaming { accumulator.finalize() } }

        let prompt = session.messages.last(where: { $0.role == .user })?.content ?? ""
        AuditLog.shared.record(sessionId: session.id, event: "turn_start", fields: [
            "agent": agent.name, "external": config.displayLine, "unattended": ToolApprovalManager.shared.isUnattended,
            "prompt": AuditLog.scrubbed(prompt),
        ])

        let promptHooks = await ToolHooks.run(.userPromptSubmit, input: ["prompt": prompt], workspaceRoot: workspace.folderPath, sessionId: session.id)
        if let reason = promptHooks.blockReason {
            accumulator.setHalt(reason: "hook", text: "A hook blocked this message: \(reason)")
            return
        }
        var promptText = prompt
        if !promptHooks.context.isEmpty { promptText += "\n\n" + promptHooks.context.joined(separator: "\n") }

        let key = "\(session.id)|\(agent.id)"
        let entry: ACPSessionPool.Entry
        let events = EventPipe()
        do {
            if let existing = await ACPSessionPool.shared.entry(for: key) {
                entry = existing
                events.attach(to: existing.connection)
            } else {
                entry = try await connect(config: config, workspace: workspace, events: events)
                await ACPSessionPool.shared.store(entry, for: key)
            }
        } catch {
            accumulator.setHalt(reason: "agent_unavailable", text: Self.startFailure(config: config, error: error))
            AuditLog.shared.record(sessionId: session.id, event: "turn_end", fields: ["reason": "agent_unavailable", "error": error.localizedDescription])
            return
        }

        let state = TurnState(accumulator: accumulator, workspace: workspace, sessionId: session.id, agentName: agent.name, onTodos: onSessionTodosUpdated)
        let sessionId = entry.sessionId
        let connection = entry.connection

        let promptTask = Task { () -> Result<String, Error> in
            do {
                let result = try await connection.request("session/prompt", [
                    "sessionId": sessionId,
                    "prompt": [["type": "text", "text": promptText]],
                ])
                return .success(result["stopReason"] as? String ?? "end_turn")
            } catch {
                return .failure(error)
            }
        }
        let finisher = Task {
            let result = await promptTask.value
            events.finish(result)
        }
        defer { finisher.cancel() }

        // The consumer is its own task so that pressing Stop does not end it: after `session/cancel`
        // the agent may still send updates, and must be allowed to answer the prompt with
        // "cancelled". If it never does, it is stopped after a grace period.
        let consumer = Task { @MainActor () -> (stopReason: String, failure: Error?) in
            var stopReason = "end_turn"
            var failure: Error?
            loop: for await event in events.stream {
                switch event {
                case let .update(kind, payload):
                    state.apply(kind: kind, payload: payload)
                case let .request(method, params, reply):
                    await state.handle(request: method, params: params, reply: reply)
                case let .finished(result):
                    switch result {
                    case .success(let reason): stopReason = reason
                    case .failure(let error): failure = error
                    }
                    break loop
                case let .closed(reason):
                    failure = ACPConnection.RemoteError(code: -32000, message: reason)
                    break loop
                }
            }
            return (stopReason, failure)
        }
        let outcome = await withTaskCancellationHandler {
            await consumer.value
        } onCancel: {
            connection.notify("session/cancel", ["sessionId": sessionId])
            Task {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                events.finish(.success("cancelled"))
                await ACPSessionPool.shared.remove(key)
            }
        }
        let stopReason = outcome.stopReason
        let failure = outcome.failure
        if failure != nil { await ACPSessionPool.shared.remove(key) }

        state.finishOpenToolCalls(cancelled: Task.isCancelled || stopReason == "cancelled")
        if let failure, !Task.isCancelled {
            accumulator.setHalt(reason: "agent_error", text: failure.localizedDescription)
        } else if Task.isCancelled || stopReason == "cancelled" {
            accumulator.setHalt(reason: "stopped", text: "Generation stopped.")
        } else if stopReason == "max_tokens" || stopReason == "max_turn_requests" {
            accumulator.setHalt(reason: "round_cap", text: "The agent stopped early (\(stopReason)). Press Continue to keep going.")
        } else if stopReason == "refusal" {
            accumulator.setHalt(reason: "refusal", text: "The agent declined to continue.")
        }
        AuditLog.shared.record(sessionId: session.id, event: "turn_end", fields: [
            "reason": failure != nil ? "agent_error" : stopReason, "agent": agent.name,
        ])
        _ = await ToolHooks.run(.stop, input: ["stop_reason": stopReason], workspaceRoot: workspace.folderPath, sessionId: session.id)
    }

    static func startFailure(config: ExternalAgentConfig, error: Error) -> String {
        "Could not start \(config.displayLine).\n\(error.localizedDescription)\n\nCheck that the program is installed and on your PATH, and that it speaks the Agent Client Protocol (Settings → External Agents)."
    }

    // MARK: - Connecting

    /// Markers a Claude Code session leaves in its children's environment. If this app was started
    /// from one, passing them on makes the agent refuse to start ("cannot be launched inside
    /// another Claude Code session"), which surfaced only as "Internal error".
    static func isInheritedClaudeSession(_ name: String) -> Bool {
        name == "CLAUDECODE" || name.hasPrefix("CLAUDE_CODE_") || name.hasPrefix("CLAUDE_AGENT_SDK_")
    }

    private static func connect(config: ExternalAgentConfig, workspace: Workspace, events: EventPipe) async throws -> ACPSessionPool.Entry {
        var environment = ToolExecutionEngine.defaultEnvironment()
        environment = environment.filter { !isInheritedClaudeSession($0.key) }
        for (name, value) in config.env { environment[name] = value }
        let connection = ACPConnection(
            executable: "/usr/bin/env", arguments: [config.command] + config.args,
            cwd: workspace.folderPath, environment: environment
        )
        events.attach(to: connection)
        do { try connection.start(onIncoming: { events.deliver($0) }) } catch {
            throw ACPConnection.RemoteError(code: -32000, message: error.localizedDescription)
        }
        let initialized = try await connection.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true]],
            "clientInfo": ["name": clientName, "title": clientName, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
        ], timeout: 60)
        if let version = initialized["protocolVersion"] as? Int, version != 1 {
            connection.stop()
            throw ACPConnection.RemoteError(code: -32002, message: "The agent speaks ACP version \(version); this app speaks version 1.")
        }
        // An agent that wants a login says so; nothing here can complete one for it.
        if let methods = initialized["authMethods"] as? [[String: Any]], !methods.isEmpty, (initialized["agentCapabilities"] as? [String: Any]) == nil {
            connection.stop()
            throw ACPConnection.RemoteError(code: -32003, message: "The agent needs you to sign in first. Run it once in a terminal to log in.")
        }
        let created = try await connection.request("session/new", ["cwd": workspace.folderPath, "mcpServers": [Any]()], timeout: 60)
        guard let sessionId = created["sessionId"] as? String else {
            connection.stop()
            throw ACPConnection.RemoteError(code: -32602, message: "The agent did not return a session id.")
        }
        let capabilities = initialized["agentCapabilities"] as? [String: Any]
        let images = ((capabilities?["promptCapabilities"] as? [String: Any])?["image"] as? Bool) ?? false
        return ACPSessionPool.Entry(connection: connection, sessionId: sessionId, lastUsed: Date(), supportsImages: images)
    }

    // MARK: - Event pipe

    enum Event: @unchecked Sendable {
        case update(kind: String, payload: [String: Any])
        case request(method: String, params: [String: Any], reply: @Sendable (Any?, (code: Int, message: String)?) -> Void)
        case finished(Result<String, Error>)
        case closed(reason: String)
    }

    /// Orders everything the agent sends, and the end of the turn, into one stream.
    final class EventPipe: @unchecked Sendable {
        let stream: AsyncStream<Event>
        private let continuation: AsyncStream<Event>.Continuation
        init() { (stream, continuation) = AsyncStream.makeStream(of: Event.self) }

        /// A pooled connection delivers into the pipe of the turn that is using it.
        func attach(to connection: ACPConnection) {
            connection.rebind { [weak self] in self?.deliver($0) }
        }

        func deliver(_ incoming: ACPConnection.Incoming) {
            switch incoming {
            case let .notification(method, params):
                guard method == "session/update", let update = params["update"] as? [String: Any],
                      let kind = update["sessionUpdate"] as? String else { return }
                continuation.yield(.update(kind: kind, payload: update))
            case let .request(method, params, reply):
                continuation.yield(.request(method: method, params: params, reply: reply))
            case let .closed(reason):
                continuation.yield(.closed(reason: reason))
            }
        }

        func finish(_ result: Result<String, Error>) {
            continuation.yield(.finished(result))
            continuation.finish()
        }
    }

    // MARK: - One turn

    @MainActor
    final class TurnState {
        let accumulator: AgentStreamAccumulator
        let workspace: Workspace
        let sessionId: String
        let agentName: String
        let onTodos: (([SessionTodoItem]) -> Void)?
        private var calls: [String: ToolCallInfo] = [:]
        private var meta: [String: (kind: String?, locations: [String], rawInput: [String: Any])] = [:]

        init(accumulator: AgentStreamAccumulator, workspace: Workspace, sessionId: String, agentName: String, onTodos: (([SessionTodoItem]) -> Void)?) {
            self.accumulator = accumulator; self.workspace = workspace; self.sessionId = sessionId
            self.agentName = agentName; self.onTodos = onTodos
        }

        func apply(kind: String, payload: [String: Any]) {
            switch kind {
            case "agent_message_chunk":
                let text = ACPMapping.text(of: payload["content"] as? [String: Any])
                if !text.isEmpty { accumulator.applyChunk(LLMStreamChunk(deltaText: text)) }
            case "agent_thought_chunk":
                let text = ACPMapping.text(of: payload["content"] as? [String: Any])
                if !text.isEmpty { accumulator.applyChunk(LLMStreamChunk(deltaReasoning: text)) }
            case "tool_call", "tool_call_update":
                applyToolCall(payload, isNew: kind == "tool_call")
            case "plan":
                let entries = (payload["entries"] as? [[String: Any]]) ?? []
                onTodos?(entries.enumerated().map { index, entry in
                    SessionTodoItem(id: "acp-\(index)", content: entry["content"] as? String ?? "", status: .init(raw: entry["status"] as? String ?? "pending"))
                })
            case "usage_update":
                if let used = payload["used"] as? Int { accumulator.applyChunk(LLMStreamChunk(promptTokens: used)) }
            default:
                break
            }
        }

        private func applyToolCall(_ payload: [String: Any], isNew: Bool) {
            guard let id = payload["toolCallId"] as? String else { return }
            var call = calls[id] ?? ToolCallInfo(id: id, toolName: (payload["name"] as? String) ?? (payload["kind"] as? String) ?? "tool", argumentsJson: "{}", status: .running)
            if let name = payload["name"] as? String { call.toolName = name }
            if let title = payload["title"] as? String, !title.isEmpty {
                call.toolName = (payload["name"] as? String) ?? call.toolName
                call.approvalReason = call.approvalReason ?? title
                titles[id] = title
            }
            var current = meta[id] ?? (kind: nil, locations: [], rawInput: [:])
            if let kind = payload["kind"] as? String { current.kind = kind }
            if let locations = payload["locations"] as? [[String: Any]] { current.locations = locations.compactMap { $0["path"] as? String } }
            if let raw = payload["rawInput"] as? [String: Any] {
                current.rawInput = raw
                if let data = try? JSONSerialization.data(withJSONObject: raw) { call.argumentsJson = String(decoding: data, as: UTF8.self) }
            }
            meta[id] = current
            if let status = payload["status"] as? String { call.status = ACPMapping.status(status) }
            if call.status == .waitingApproval, payload["status"] != nil { call.status = ACPMapping.status(payload["status"] as? String) }
            for item in (payload["content"] as? [[String: Any]]) ?? [] {
                switch item["type"] as? String {
                case "content":
                    let text = ACPMapping.text(of: item["content"] as? [String: Any])
                    if !text.isEmpty { call.resultOutput = ((call.resultOutput ?? "").isEmpty ? "" : call.resultOutput! + "\n") + text }
                case "diff":
                    if let path = item["path"] as? String {
                        let diff = InlineFileDiff.between(before: item["oldText"] as? String, after: item["newText"] as? String, path: path)
                        if let diff { call.fileDiffs = (call.fileDiffs ?? []) + [diff]; call.fileDiff = nil }
                    }
                default:
                    break
                }
            }
            if call.status == .error, (call.errorMessage ?? "").isEmpty { call.errorMessage = call.resultOutput ?? "The tool failed." }
            let known = calls[id] != nil
            calls[id] = call
            if known { accumulator.updateToolCall(call) } else { accumulator.addToolCall(call) }
        }

        private var titles: [String: String] = [:]

        /// Calls still open when the turn ends were interrupted, not completed.
        func finishOpenToolCalls(cancelled: Bool) {
            for (id, var call) in calls where call.status == .running || call.status == .waitingApproval {
                call.status = cancelled ? .error : .success
                if cancelled { call.errorMessage = "Cancelled." }
                calls[id] = call
                accumulator.updateToolCall(call)
            }
        }

        // MARK: Requests from the agent

        func handle(request method: String, params: [String: Any], reply: @Sendable (Any?, (code: Int, message: String)?) -> Void) async {
            switch method {
            case "session/request_permission":
                reply(await permission(params), nil)
            case "fs/read_text_file":
                let outcome = readFile(params)
                reply(outcome.result, outcome.error)
            case "fs/write_text_file":
                let outcome = await writeFile(params)
                reply(outcome.result, outcome.error)
            default:
                reply(nil, (-32601, "Method not supported: \(method)"))
            }
        }

        /// The agent asks; our rules and approval level answer.
        private func permission(_ params: [String: Any]) async -> [String: Any] {
            let options = (params["options"] as? [[String: Any]]) ?? []
            let update = params["toolCall"] as? [String: Any] ?? [:]
            guard let id = update["toolCallId"] as? String else { return ["outcome": ["outcome": "cancelled"]] }
            // The request may carry fresher details than the tool_call that announced it.
            applyToolCall(update, isNew: false)
            let info = meta[id] ?? (kind: nil, locations: [], rawInput: [:])
            let title = titles[id] ?? (update["title"] as? String) ?? "an action"
            let equivalent = ACPMapping.equivalentTool(kind: info.kind, rawInput: info.rawInput, locations: info.locations)
            let arguments = equivalent.flatMap { try? JSONSerialization.data(withJSONObject: $0.arguments) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"

            func answer(_ approved: Bool, decision: AuditLog.Decision, note: String?) -> [String: Any] {
                AuditLog.shared.toolCall(sessionId: sessionId, tool: equivalent?.tool ?? (info.kind ?? "external"), argumentsJson: arguments, decision: decision, success: approved, note: "\(agentName): \(title)" + (note.map { " — \($0)" } ?? ""))
                guard let option = ACPMapping.optionId(for: approved, in: options) else { return ["outcome": ["outcome": "cancelled"]] }
                return ["outcome": ["outcome": "selected", "optionId": option]]
            }

            if let equivalent, let verdict = PermissionRules.verdict(toolName: equivalent.tool, argumentsJson: arguments, workspaceRoot: workspace.folderPath) {
                if verdict.action == .deny { return answer(false, decision: .deniedByRule, note: verdict.explanation) }
                if verdict.action == .allow { return answer(true, decision: .automatic, note: verdict.explanation) }
            }
            let settings = PersistenceManager.shared.loadSettings()
            if settings.terminalSafetyLevel == .allowEverything { return answer(true, decision: .automatic, note: "Allow All") }

            var call = calls[id] ?? ToolCallInfo(id: id, toolName: info.kind ?? "tool", argumentsJson: arguments, status: .running)
            call.status = .waitingApproval
            call.approvalReason = "\(agentName) asks to: \(title)"
            calls[id] = call
            accumulator.updateToolCall(call)
            let outcome = await ToolApprovalManager.shared.requestApproval(
                callId: id, toolName: call.toolName, argumentsJson: call.argumentsJson, reason: call.approvalReason ?? title
            )
            call.status = .running
            calls[id] = call
            accumulator.updateToolCall(call)
            switch outcome {
            case .approved: return answer(true, decision: .approved, note: nil)
            case .rejected: return answer(false, decision: .rejected, note: nil)
            case .refusedUnattended: return answer(false, decision: .refusedUnattended, note: "unattended")
            }
        }

        // MARK: File access the agent performs through us

        private func resolve(_ path: String) -> String? {
            guard path.hasPrefix("/") else { return nil }   // ACP paths are absolute
            let resolved = ToolExecutionEngine.canonicalPath(path)
            let settings = PersistenceManager.shared.loadSettings()
            let roots = ([workspace.folderPath] + settings.authorizedFolders).map { ToolExecutionEngine.canonicalPath($0) }
            return roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) ? resolved : nil
        }

        private func readFile(_ params: [String: Any]) -> (result: Any?, error: (code: Int, message: String)?) {
            guard let path = params["path"] as? String, let resolved = resolve(path) else {
                return (nil, (-32602, "That path is outside the workspace."))
            }
            if let reason = SensitivePaths.reason(forReading: resolved, workspaceRoot: workspace.folderPath) {
                return (nil, (-32602, "Not readable without the user's say-so: \(reason)"))
            }
            guard var text = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                return (nil, (-32002, "Could not read \(path)."))
            }
            if let start = params["line"] as? Int, start > 1 || params["limit"] != nil {
                let lines = text.components(separatedBy: "\n")
                let from = max(0, start - 1)
                let count = (params["limit"] as? Int) ?? lines.count
                text = lines.dropFirst(from).prefix(max(0, count)).joined(separator: "\n")
            }
            return (["content": text], nil)
        }

        private func writeFile(_ params: [String: Any]) async -> (result: Any?, error: (code: Int, message: String)?) {
            guard let path = params["path"] as? String, let resolved = resolve(path), let content = params["content"] as? String else {
                return (nil, (-32602, "That path is outside the workspace."))
            }
            let arguments = (try? JSONSerialization.data(withJSONObject: ["path": resolved, "content": content])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            // Through the same engine as our own writes: boundary check, undo checkpoint, permission
            // rules, hooks, language-server refresh.
            let result = await ToolExecutionEngine.shared.execute(toolName: "file_write", argumentsJson: arguments, workspace: workspace, currentAgent: Agent(name: agentName))
            return result.success ? (NSNull(), nil) : (nil, (-32002, result.error ?? "Could not write \(path)."))
        }
    }
}

extension ACPConnection {
    /// Point an already-running connection at a new consumer, for a turn on a pooled session.
    func rebind(_ handler: @escaping @Sendable (Incoming) -> Void) {
        setIncomingHandler(handler)
    }
}
