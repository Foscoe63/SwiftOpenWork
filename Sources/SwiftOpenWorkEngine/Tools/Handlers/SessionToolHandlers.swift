import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Tools that act on the session itself: questions, todos, memory, skills, small utilities.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let sessionToolHandlers: [ToolRegistration] = [
        ToolRegistration(["ask_user"]) { await $0.askUserTool($1) },
        ToolRegistration(["exit_plan_mode"]) { await $0.exitPlanModeTool($1) },
        ToolRegistration(["todo_write"]) { await $0.todoWriteTool($1) },
        ToolRegistration(["calculator"]) { await $0.calculatorTool($1) },
        ToolRegistration(["get_current_date", "get_date", "current_date", "date"]) { await $0.getCurrentDateTool($1) },
        ToolRegistration(["memory_store"]) { await $0.memoryStoreTool($1) },
        ToolRegistration(["memory_recall"]) { await $0.memoryRecallTool($1) },
        ToolRegistration(["tool_describe"]) { await $0.toolDescribeTool($1) },
        ToolRegistration(["skill_load"]) { await $0.skillLoadTool($1) },
        ToolRegistration(["recall_output"]) { await $0.recallOutputTool($1) },
    ]

    func askUserTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let startTime = call.startTime
        return ToolExecutionResult(
            success: false,
            output: "",
            error: "ask_user is handled by AgentRunner (not ToolExecutionEngine)",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func exitPlanModeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let startTime = call.startTime
        return ToolExecutionResult(
            success: true,
            output: "Plan mode exited.",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func todoWriteTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        // Only an explicit empty list clears. Missing or unreadable `items` used to default to
        // `[]`, so a local model sending `todo_write {}` four times in a row wiped a ten-item
        // plan the user was following, and was told "Todo list cleared." as if it had asked.
        guard let items = Self.todoItems(from: dict) else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "todo_write needs `items`: the full list, e.g. {\"items\":[{\"content\":\"…\",\"status\":\"pending\"}]}. "
                    + "The list was left unchanged. Send `\"items\": []` only to clear it on purpose.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let todos = SessionTodoItem.parse(from: items)
        if todos.isEmpty && !items.isEmpty {
            return ToolExecutionResult(
                success: false, output: "",
                error: "todo_write: none of the \(items.count) item(s) had a `content` string. The list was left unchanged.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let summary = todos.prefix(20).enumerated().map { idx, item in
            "\(idx + 1). [\(item.status.rawValue)] \(item.content)"
        }.joined(separator: "\n")
        return ToolExecutionResult(
            success: true,
            output: todos.isEmpty
                ? "Todo list cleared."
                : "Todo list updated (\(todos.count) items):\n\(summary)",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
            sessionTodos: todos
        )
    }

    func calculatorTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        let expr = dict["expression"] as? String ?? ""
        return evaluateMath(expression: expr, startTime: startTime)
    }

    func getCurrentDateTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let startTime = call.startTime
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        let zone = TimeZone.current
        let weekday = DateFormatter()
        weekday.locale = formatter.locale
        weekday.dateFormat = "EEEE"
        let now = Date()
        let dateStr = "\(formatter.string(from: now)) (\(weekday.string(from: now)), \(zone.identifier))"
        return ToolExecutionResult(
            success: true,
            output: dateStr,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func memoryStoreTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let currentAgent = call.currentAgent
        let startTime = call.startTime
        let key = dict["key"] as? String ?? "general_note"
        let content = dict["content"] as? String ?? ""
        let item = MemoryItem(
            workspaceId: workspace.id,
            key: key,
            content: content,
            category: .fact,
            tags: [currentAgent.name]
        )
        if (dict["scope"] as? String)?.lowercased() == "project" {
            guard !content.isEmpty,
                  MemoryPrompt.appendToProjectFile(key: key, content: content, workspaceRoot: workspace.folderPath) else {
                return ToolExecutionResult(success: false, output: "", error: "Could not write \(MemoryPrompt.projectFileRelativePath).",
                                           durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            }
            return ToolExecutionResult(
                success: true,
                output: "Saved [\(key)] to \(MemoryPrompt.projectFileRelativePath); every agent working in this project will see it.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        PersistenceManager.shared.saveMemories(MemoryPrompt.upserting(item, into: PersistenceManager.shared.loadMemories()))
        return ToolExecutionResult(
            success: true,
            output: "Stored fact to long-term memory with key: [\(key)]",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func memoryRecallTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let query = dict["query"] as? String ?? ""
        // This workspace's memories, plus the shared ones saved before they were scoped. A
        // fact learned in one project used to surface in every other.
        let mems = PersistenceManager.shared.loadMemories().filter {
            $0.workspaceId == workspace.id || $0.workspaceId == "default-workspace"
        }
        let filtered = mems.filter {
            query.isEmpty ||
            $0.key.localizedCaseInsensitiveContains(query) ||
            $0.content.localizedCaseInsensitiveContains(query)
        }
        if filtered.isEmpty {
            return ToolExecutionResult(
                success: true,
                output: "No memory items found matching query '\(query)'",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let text = filtered.prefix(5).map { "- [\($0.key)] \($0.content)" }.joined(separator: "\n")
        return ToolExecutionResult(
            success: true,
            output: "### Recalled Memories:\n\(text)",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func toolDescribeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        let query = dict["query"] as? String ?? dict["name"] as? String ?? dict["tool"] as? String ?? ""
        let limit = (dict["limit"] as? Int) ?? Int(dict["limit"] as? String ?? "") ?? MCPToolSearch.defaultLimit
        let pool = PersistenceManager.shared.loadTools().filter { $0.isEnabled && BuiltInToolSearch.deferrable.contains($0.name) }
            + ToolSchemaCatalog.parityDefaults.filter { BuiltInToolSearch.deferrable.contains($0.name) }
        var seen = Set<String>()
        let unique = pool.filter { seen.insert($0.name).inserted }
        let found = MCPToolSearch.match(query: query, in: unique, limit: limit)
        guard !found.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "No deferred tool matches '\(query)'. Try fewer or different words, or a tool name from the list.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        return ToolExecutionResult(
            success: true,
            output: "\(found.count) tool(s) loaded; call them directly by these names.\n\n" + MCPToolSearch.describe(found),
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func skillLoadTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let currentAgent = call.currentAgent
        let startTime = call.startTime
        let requested = (dict["name"] as? String ?? dict["skill"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let everySkill = PersistenceManager.shared.loadSkills()
            + ProjectSkills.load(workspacePath: workspace.folderPath)
            + ProjectSkills.loadGlobal()
        let skills = everySkill.filter { $0.isEnabled && $0.isAllowed(by: currentAgent.allowedSkillIds) }
        // `_new-mac-app` and `new-mac-app` are the same skill to anyone typing a name.
        func normalized(_ name: String) -> String {
            name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        }
        let key = normalized(requested)
        guard !key.isEmpty,
              let skill = skills.first(where: { normalized($0.name) == key })
                ?? skills.first(where: { normalized($0.name).contains(key) }) else {
            // A skill that exists but is switched off, or not granted to this agent, is a
            // different failure from a typo. Said plainly, the model stops hunting for its
            // SKILL.md through the shell (one session spent ten rounds doing exactly that).
            let blocked = !key.isEmpty && everySkill.contains { normalized($0.name) == key }
            let message = blocked
                ? "Skill '\(requested)' is installed but not enabled for this agent, so it cannot be loaded. "
                    + "Do not look for its files with the shell. Carry on without it, or tell the user to enable it. "
                    + "Available: \(skills.map(\.name).sorted().joined(separator: ", "))."
                : "No skill named '\(requested)'. Available: \(skills.map(\.name).sorted().joined(separator: ", "))."
            return ToolExecutionResult(
                success: false, output: "",
                error: message,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let body = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolExecutionResult(
            success: true,
            output: "# Skill: \(skill.name)\n\n" + (body.isEmpty ? skill.description : body),
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func recallOutputTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        func intArgument(_ key: String) -> Int? { (dict[key] as? Int) ?? Int(dict[key] as? String ?? "") }
        let recalled = ToolOutputStore.shared.recall(
            id: dict["id"] as? String ?? dict["output_id"] as? String ?? "",
            query: dict["query"] as? String ?? dict["search"] as? String ?? dict["q"] as? String,
            start: intArgument("start") ?? intArgument("offset"),
            lines: intArgument("lines") ?? intArgument("limit"),
            sessionId: AgentRunContext.current?.sessionId
        )
        return ToolExecutionResult(
            success: recalled.success,
            output: recalled.success ? recalled.text : "",
            error: recalled.success ? nil : recalled.text,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }
}
