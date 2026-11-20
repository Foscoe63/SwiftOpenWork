import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// `code_mode`: one JavaScript program that calls other tools, so a job that would take twenty
// model round trips takes one and only its result enters the conversation.
//
// A call a script makes is judged exactly like the same call made directly: the agent's tool list,
// plan mode, approval (which asks the person, or is refused in an unattended run), and then
// `ToolExecutionEngine.execute`, where standing rules, hooks and the audit log apply.

/// What a script may not call, and why. Pure, so the rules are tested without a runtime.
enum CodeModePolicy {

    /// Tools that make no sense from inside a script, or that must stay the agent's own decision.
    static let neverCallable: Set<String> = [
        "code_mode",        // a script inside a script only hides its calls
        "ask_user",         // answered by the loop, not the dispatcher
        "exit_plan_mode",   // lifting the guard is for the person to approve, in the open
        "worktree_merge",   // writes into the user's checkout
        "agent_spawn", "agent_message",
        "send_input",       // drives an interactive program one keystroke at a time
    ]

    static let maxCallsPerScript = 100

    /// The line in the system prompt that tells the model when to reach for `code_mode`. Empty
    /// when the tool is not offered, so a prompt never names a tool the agent does not have.
    static func promptHint(offered: Bool) -> String {
        guard offered else { return "" }
        return """
        code_mode: when a job needs many tool calls (reading or searching across many files, \
        looping over results, filtering or counting before you answer), write ONE script with \
        code_mode instead of calling tools one round at a time: \
        `const r = await tools.grep({pattern: "TODO"}); return r.split("\\n").length;` \
        Only what the script returns reaches you. For one or two calls, call the tools directly.
        """
    }

    /// Why `toolName` may not run from a script, or nil. `offered` is the canonical names of the
    /// built-in tools this agent has; nil skips that check.
    static func refusal(toolName: String, offered: Set<String>?, settings: AppSettings) -> String? {
        let canonical = ToolCallRepair.builtInCanonical(toolName)
        let name = canonical ?? toolName
        if neverCallable.contains(name) {
            return "`\(name)` cannot be called from code_mode. Call it directly instead."
        }
        if settings.planModeEnabled, ToolCallRepair.isBlockedInPlanMode(toolName) {
            return "Plan mode is on, so `\(name)` (it changes files or runs commands) was not run."
        }
        if let canonical, let offered, !offered.contains(canonical) {
            return "`\(name)` is not enabled for this agent."
        }
        return nil
    }

    /// `name(arg*, optional)` for each tool, from its JSON schema: enough to write a call without
    /// loading every schema in full.
    static func signature(name: String, schemaJson: String) -> String {
        guard let data = schemaJson.data(using: .utf8),
              let schema = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let properties = schema["properties"] as? [String: Any], !properties.isEmpty else {
            return "tools.\(name)()"
        }
        let required = Set((schema["required"] as? [String]) ?? [])
        let parts = properties.keys.sorted { a, b in
            (required.contains(a) ? 0 : 1, a) < (required.contains(b) ? 0 : 1, b)
        }.map { key -> String in
            let type = ((properties[key] as? [String: Any])?["type"] as? String) ?? "any"
            return "\(key)\(required.contains(key) ? "" : "?"): \(type)"
        }
        return "tools.\(name)({ \(parts.joined(separator: ", ")) })"
    }

    /// The text a script's run becomes in the transcript.
    static func report(_ outcome: CodeModeRuntime.Outcome, trace: [String]) -> String {
        var sections: [String] = []
        if let error = outcome.error {
            sections.append("Script failed: \(error)")
        } else {
            let value = outcome.value ?? ""
            sections.append(value.isEmpty ? "(the script returned nothing; `return` the value you want)" : value)
        }
        if !outcome.logs.isEmpty {
            sections.append("[console]\n" + outcome.logs.joined(separator: "\n"))
        }
        if !trace.isEmpty {
            let shown = trace.prefix(40)
            let more = trace.count > shown.count ? ["… and \(trace.count - shown.count) more"] : []
            sections.append("[\(outcome.callCount) tool call\(outcome.callCount == 1 ? "" : "s")]\n" + (Array(shown) + more).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

/// Lets reads run side by side (up to `maxReaders`) and everything else run alone, so a script
/// that does `Promise.all` over reads is fast and one that edits files cannot race itself.
actor CodeModeGate {
    static let maxReaders = 4
    private var readers = 0
    private var writing = false
    private var waiting: [(exclusive: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func acquire(exclusive: Bool) async {
        if waiting.isEmpty, canStart(exclusive) { start(exclusive); return }
        await withCheckedContinuation { waiting.append((exclusive, $0)) }
    }

    func release(exclusive: Bool) {
        if exclusive { writing = false } else { readers -= 1 }
        while let next = waiting.first, canStart(next.exclusive) {
            waiting.removeFirst()
            start(next.exclusive)
            next.continuation.resume()
        }
    }

    private func canStart(_ exclusive: Bool) -> Bool {
        exclusive ? (!writing && readers == 0) : (!writing && readers < Self.maxReaders)
    }

    private func start(_ exclusive: Bool) {
        if exclusive { writing = true } else { readers += 1 }
    }
}

extension ToolExecutionEngine {
    static let codeModeToolHandlers: [ToolRegistration] = [
        ToolRegistration(["code_mode"]) { await $0.codeModeTool($1) },
    ]

    func codeModeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        let settings = call.settings
        let workspace = call.workspace
        let agent = call.currentAgent
        let outerCallId = call.callId

        func failure(_ message: String) -> ToolExecutionResult {
            Self.failure(message, startTime)
        }
        guard settings.enableCodeMode else {
            return failure("Code Mode is off. Turn it on under Settings → Permissions, or make these calls one at a time.")
        }

        let offered = await Self.codeModeOfferedTools(agent: agent, settings: settings)

        if (dict["list_tools"] as? Bool) == true {
            return ToolExecutionResult(
                success: true, output: await Self.codeModeToolList(offered: offered, settings: settings),
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }

        let code = ((dict["code"] as? String) ?? (dict["script"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            return failure("code_mode needs `code`: the body of an async JavaScript function, e.g. `const files = await tools.glob({pattern: \"**/*.swift\"}); return files.split(\"\\n\").length;`. Pass list_tools=true to see what tools.* offers.")
        }

        var limits = CodeModeRuntime.Limits()
        limits.maxCalls = CodeModePolicy.maxCallsPerScript
        if let requested = Self.intArgument(dict["timeout_seconds"]) {
            limits.wallSeconds = Double(min(600, max(5, requested)))
        }

        let offeredNames = Set(offered.map { AgentRunner.canonicalToolName($0.name) })
        let frameDepth = AgentRunContext.current?.depth ?? 0
        let sessionId = AgentRunContext.current?.sessionId ?? ""
        let gate = CodeModeGate()
        let trace = CodeModeTrace()

        let invoker: CodeModeRuntime.Invoker = { [self] name, argsJson, number in
            let innerId = "\(outerCallId ?? "code-mode")-js\(number)"
            let started = CFAbsoluteTimeGetCurrent()
            let result = await self.runInnerCall(
                name: name, argumentsJson: argsJson, innerId: innerId, workspace: workspace, agent: agent,
                settings: settings, offered: offeredNames, depth: frameDepth, sessionId: sessionId, gate: gate
            )
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            let line: String
            switch result {
            case .success: line = "\(number). \(name) ok \(ms)ms"
            case .failure(let failure): line = "\(number). \(name) failed: \(failure.message.prefix(120))"
            }
            trace.add(number, line)
            LiveToolOutput.note(line, callId: outerCallId)
            return result
        }

        let outcome = await CodeModeRuntime.run(code: code, limits: limits, invoke: invoker)
        let output = CodeModePolicy.report(outcome, trace: trace.lines)
        return ToolExecutionResult(
            success: outcome.succeeded, output: output,
            error: outcome.error, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    // MARK: - One call from a script

    private func runInnerCall(
        name: String, argumentsJson: String, innerId: String, workspace: Workspace, agent: Agent,
        settings: AppSettings, offered: Set<String>, depth: Int, sessionId: String, gate: CodeModeGate
    ) async -> Result<String, CodeModeCallFailure> {
        func refuse(_ message: String) -> Result<String, CodeModeCallFailure> {
            .failure(CodeModeCallFailure(message: message))
        }
        if Task.isCancelled { return refuse("The script has been stopped.") }

        if let refusal = CodeModePolicy.refusal(toolName: name, offered: offered, settings: settings) {
            return refuse(refusal)
        }
        if MCPNamespacedTool.isNamespaced(name) {
            if !SubAgentExecutor.agentAllowsMCP(toolId: name, toolName: name, agent: agent, settings: settings) {
                return refuse("`\(name)` is not enabled for this agent.")
            }
            if settings.planModeEnabled,
               await AgentRunner.planModeRefusesMCP(toolName: name, argumentsJson: argumentsJson, settings: settings) {
                return refuse("Plan mode is on, so `\(name)` (an MCP tool that may change data) was not run.")
            }
        } else if ToolCallRepair.builtInCanonical(name) == nil {
            return refuse("Unknown tool `\(name)`. Call code_mode with list_tools=true to see the names.")
        }

        // The same approval a direct call would face. A sub-agent is held to its stricter policy.
        let reason: String? = await MainActor.run {
            if depth > 0 {
                return SubAgentToolPolicy.approvalReason(
                    toolName: name, argumentsJson: argumentsJson, worktreePath: nil,
                    settings: settings, sessionId: sessionId, workspaceRoot: workspace.folderPath
                )
            }
            return AgentRunner.approvalReason(
                toolName: name, argumentsJson: argumentsJson, settings: settings,
                sessionId: sessionId, workspaceRoot: workspace.folderPath
            )
        }
        if let reason {
            let outcome = await ToolApprovalManager.shared.requestApproval(
                callId: innerId, toolName: name, argumentsJson: argumentsJson, reason: "A code_mode script wants to run this. \(reason)"
            )
            if outcome != .approved {
                AuditLog.shared.toolCall(
                    sessionId: sessionId, tool: name, argumentsJson: argumentsJson,
                    decision: outcome == .refusedUnattended ? .refusedUnattended : .rejected,
                    success: false, note: reason
                )
                return refuse(outcome == .refusedUnattended
                    ? "Skipped: needs approval (\(reason)) and this run is unattended."
                    : "Blocked: the user did not approve this action (\(reason)).")
            }
            await MainActor.run {
                AgentRunner.rememberApprovedFetch(toolName: name, argumentsJson: argumentsJson, sessionId: sessionId)
            }
        }

        let exclusive = !AgentRunner.isParallelSafe(name)
        await gate.acquire(exclusive: exclusive)
        let result: ToolExecutionResult
        if Task.isCancelled {
            await gate.release(exclusive: exclusive)
            return refuse("The script has been stopped.")
        }
        result = await execute(
            toolName: name, argumentsJson: argumentsJson, workspace: workspace,
            currentAgent: agent, callId: innerId
        )
        await gate.release(exclusive: exclusive)

        let output = CodeModeRuntime.bounded(result.output, to: 100_000)
        if result.success { return .success(output) }
        let message = [result.error, result.output.isEmpty ? nil : output].compactMap { $0 }.joined(separator: "\n")
        return refuse(message.isEmpty ? "`\(name)` failed." : message)
    }

    // MARK: - Tool list

    /// The built-in tools this agent has, as `SubAgentExecutor` would offer a sub-agent of the
    /// same configuration.
    @MainActor
    private static func codeModeOfferedTools(agent: Agent, settings: AppSettings) -> [Tool] {
        var all = PersistenceManager.shared.loadTools()
        _ = ToolSchemaCatalog.ensureParityTools(in: &all)
        return SubAgentExecutor.toolSet(for: agent, depth: AgentRunContext.current?.depth ?? 0, settings: settings, all: all)
            .filter { !CodeModePolicy.neverCallable.contains($0.name) }
    }

    private static func codeModeToolList(offered: [Tool], settings: AppSettings) async -> String {
        var lines = ["Call these as `await tools.<name>(args)`. Each returns the tool's output text, or throws an Error with the reason.", ""]
        for tool in offered.sorted(by: { $0.name < $1.name }) where !MCPNamespacedTool.isNamespaced(tool.name) {
            lines.append(CodeModePolicy.signature(name: tool.name, schemaJson: tool.parametersJsonSchema))
        }
        let advertised = await MCPClientManager.shared.advertisedToolNames()
        let enabled = Set(settings.mcpServers.filter(\.isEnabled).map(\.id))
        let mcp = advertised.filter { enabled.contains($0.key) }.sorted { $0.key < $1.key }
        if !mcp.isEmpty {
            lines.append("")
            lines.append("MCP tools (use the quoted name: `await tools[\"<name>\"](args)`):")
            for (server, names) in mcp {
                for name in names.sorted() { lines.append("  \"\(MCPNamespacedTool.name(serverId: server, toolName: name))\"") }
            }
        }
        lines.append("")
        lines.append("Also: `sleep(ms)` (max 10s), `console.log(...)`. Use Promise.all for independent reads. At most \(CodeModePolicy.maxCallsPerScript) calls per script.")
        return lines.joined(separator: "\n")
    }
}

/// Call lines gathered from concurrent calls, kept in call order.
final class CodeModeTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(number: Int, line: String)] = []

    func add(_ number: Int, _ line: String) {
        lock.lock(); entries.append((number, line)); lock.unlock()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.sorted { $0.number < $1.number }.map(\.line)
    }
}
