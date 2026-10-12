import Foundation
import CryptoKit
import SwiftOpenWorkCore

public enum HookEvent: String, Sendable, CaseIterable {
    /// Before a tool runs. Can block it.
    case preToolUse = "PreToolUse"
    /// After a tool ran. Can add a note for the model.
    case postToolUse = "PostToolUse"
    /// When a message is sent. Can block the turn or add context.
    case userPromptSubmit = "UserPromptSubmit"
    /// When a turn ends. Observational.
    case stop = "Stop"
}

public struct HookCommand: Equatable, Sendable {
    public var command: String
    public var timeout: TimeInterval
    /// Where it came from: a project file needs trust, the global one does not.
    public var isProject: Bool
}

struct HookGroup: Equatable, Sendable {
    var matcher: String
    var commands: [HookCommand]
}

public struct HookOutcome: Sendable, Equatable {
    /// Set when a hook refused the call (PreToolUse) or the message (UserPromptSubmit).
    public var blockReason: String?
    /// Text for the model: feedback after a tool, or context with a prompt.
    public var context: [String] = []
    /// Things the person should hear about: a hook that crashed, timed out, or was skipped.
    public var notices: [String] = []

    public var isBlocked: Bool { blockReason != nil }
    public static let none = HookOutcome()
}

/// Lifecycle hooks: commands you own, run by the app at fixed points, so a rule holds whether or
/// not the model remembers it.
///
/// A skill or a line in `AGENTS.md` is advice; the model may not follow it. A hook is enforced by
/// the app: "run the formatter after every edit", "never let a command touch `migrations/`", "tell
/// me when a turn ends".
///
/// Configured in `~/.swiftopenwork/hooks.json` (yours) and `.swiftopenwork/hooks.json` in the
/// workspace. The shape is Claude Code's, so a file written for it works here:
///
/// ```json
/// { "hooks": { "PreToolUse": [ { "matcher": "file_write|edit_file",
///     "hooks": [ { "type": "command", "command": "./scripts/guard.sh", "timeout": 10 } ] } ] } }
/// ```
///
/// A hook gets one JSON object on stdin (`hook_event_name`, `tool_name`, `tool_input`, `cwd`, and
/// for PostToolUse `tool_response`). Exit 0 lets things go on; stdout may be JSON
/// (`{"decision":"block","reason":"…"}`, `{"additionalContext":"…"}`). **Exit 2 blocks**, with
/// stderr as the reason handed back to the model. Any other exit is a failure of the hook itself:
/// reported to you, not held against the agent.
///
/// **A project's hooks are code that arrives with a checkout**, so they do not run until you trust
/// that exact file; changing it withdraws the trust.
public enum ToolHooks {
    public static let relativePath = ".swiftopenwork/hooks.json"
    public static let defaultTimeout: TimeInterval = 30
    static let maxCapturedBytes = 64 * 1024

    /// Tests point this somewhere empty so the machine's own hooks cannot change their outcome.
    nonisolated(unsafe) public static var globalPathOverride: String?

    public static var globalPath: String {
        if let globalPathOverride { return globalPathOverride }
        return AppIdentity.homeDataDirectory.appendingPathComponent("hooks.json").path
    }

    public static func projectPath(workspaceRoot: String) -> String {
        (workspaceRoot as NSString).appendingPathComponent(relativePath)
    }

    // MARK: - Parsing

    static func parse(_ data: Data, isProject: Bool) -> [HookEvent: [HookGroup]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let table = (root["hooks"] as? [String: Any]) ?? root
        var result: [HookEvent: [HookGroup]] = [:]
        for event in HookEvent.allCases {
            guard let groups = table[event.rawValue] as? [Any] else { continue }
            for case let group as [String: Any] in groups {
                let matcher = (group["matcher"] as? String) ?? "*"
                var commands: [HookCommand] = []
                for case let entry as [String: Any] in (group["hooks"] as? [Any]) ?? [] {
                    guard (entry["type"] as? String ?? "command") == "command",
                          let command = entry["command"] as? String,
                          !command.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let timeout = (entry["timeout"] as? Double) ?? (entry["timeout"] as? Int).map(Double.init) ?? defaultTimeout
                    commands.append(HookCommand(command: command, timeout: min(max(timeout, 1), 600), isProject: isProject))
                }
                if !commands.isEmpty { result[event, default: []].append(HookGroup(matcher: matcher, commands: commands)) }
            }
        }
        return result
    }

    /// `Edit|Write`, `file_*`, `*`, or empty. Case-insensitive, and the names Claude Code uses for
    /// its tools are understood, so a file written for it applies to the same actions here.
    static func matcher(_ matcher: String, matches toolName: String) -> Bool {
        let trimmed = matcher.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" { return true }
        let canonical = ToolCallRepair.builtInCanonical(toolName)
        let names = Set([toolName, canonical].compactMap { $0 }.map { $0.lowercased() })
            .union(compatibilityNames(for: canonical ?? toolName))
        return trimmed.split(separator: "|").contains { part in
            let pattern = part.trimmingCharacters(in: .whitespaces).lowercased()
            return names.contains { CodeSearch.matchSegment($0, pattern: pattern) }
        }
    }

    private static func compatibilityNames(for canonical: String) -> Set<String> {
        switch canonical {
        case "terminal_command", "run_command": return ["bash"]
        case "file_write", "write_file", "create_file": return ["write"]
        case "edit_file", "file_edit": return ["edit"]
        case "multi_edit": return ["multiedit", "edit"]
        case "file_read", "read_file": return ["read"]
        case "grep": return ["grep"]
        case "glob": return ["glob"]
        case "fetch_url": return ["webfetch"]
        case "web_search": return ["websearch"]
        default: return []
        }
    }

    // MARK: - Trust

    public enum ProjectStatus: Equatable, Sendable {
        case none
        case trusted
        /// The file exists and has not been approved (or has changed since). `commands` is what it would run.
        case untrusted(commands: [String])
    }

    private static let trustKey = "toolHooks.trustedDigests"

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func projectStatus(workspaceRoot: String) -> ProjectStatus {
        let path = projectPath(workspaceRoot: workspaceRoot)
        guard !workspaceRoot.isEmpty, let data = FileManager.default.contents(atPath: path) else { return .none }
        let table = AppIdentity.defaults.dictionary(forKey: trustKey) as? [String: String] ?? [:]
        if table[ToolExecutionEngine.canonicalPath(workspaceRoot)] == digest(of: data) { return .trusted }
        let commands = parse(data, isProject: true).values.flatMap { $0 }.flatMap(\.commands).map(\.command)
        return commands.isEmpty ? .none : .untrusted(commands: commands)
    }

    /// Approve the file as it is now. Editing it afterwards withdraws the approval.
    public static func trustProject(workspaceRoot: String) {
        guard let data = FileManager.default.contents(atPath: projectPath(workspaceRoot: workspaceRoot)) else { return }
        var table = AppIdentity.defaults.dictionary(forKey: trustKey) as? [String: String] ?? [:]
        table[ToolExecutionEngine.canonicalPath(workspaceRoot)] = digest(of: data)
        AppIdentity.defaults.set(table, forKey: trustKey)
    }

    public static func revokeProjectTrust(workspaceRoot: String) {
        var table = AppIdentity.defaults.dictionary(forKey: trustKey) as? [String: String] ?? [:]
        table.removeValue(forKey: ToolExecutionEngine.canonicalPath(workspaceRoot))
        AppIdentity.defaults.set(table, forKey: trustKey)
    }

    /// Every hook that may run for this workspace, with the reason any were left out.
    static func load(workspaceRoot: String) -> (groups: [HookEvent: [HookGroup]], skipped: String?) {
        var merged: [HookEvent: [HookGroup]] = [:]
        if let data = FileManager.default.contents(atPath: globalPath) {
            merged = parse(data, isProject: false)
        }
        var skipped: String?
        switch projectStatus(workspaceRoot: workspaceRoot) {
        case .none:
            break
        case .trusted:
            if let data = FileManager.default.contents(atPath: projectPath(workspaceRoot: workspaceRoot)) {
                for (event, groups) in parse(data, isProject: true) { merged[event, default: []] += groups }
            }
        case let .untrusted(commands):
            skipped = "This project defines \(commands.count) hook command\(commands.count == 1 ? "" : "s") in \(relativePath), which are not running until you trust them (Settings → Safety → Hooks)."
        }
        return (merged, skipped)
    }

    // MARK: - Running

    /// Run every hook for `event` that matches. Hooks for one event run one after another, in file
    /// order, and a block stops the rest.
    public static func run(
        _ event: HookEvent,
        toolName: String? = nil,
        input: [String: Any] = [:],
        workspaceRoot: String,
        sessionId: String? = nil
    ) async -> HookOutcome {
        guard !workspaceRoot.isEmpty || FileManager.default.fileExists(atPath: globalPath) else { return .none }
        let loaded = load(workspaceRoot: workspaceRoot)
        var outcome = HookOutcome()
        if let skipped = loaded.skipped, event == .userPromptSubmit { outcome.notices.append(skipped) }
        let commands = (loaded.groups[event] ?? [])
            .filter { toolName == nil || matcher($0.matcher, matches: toolName!) }
            .flatMap(\.commands)
        guard !commands.isEmpty else { return outcome }

        var payload = input
        payload["hook_event_name"] = event.rawValue
        payload["cwd"] = workspaceRoot
        if let sessionId { payload["session_id"] = sessionId }
        if let toolName { payload["tool_name"] = toolName }
        let stdin = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)

        for hook in commands {
            let ran = await execute(hook, stdin: stdin, workspaceRoot: workspaceRoot)
            AppLog.verbose(.tools, "hook \(event.rawValue) exit=\(ran.exitCode)\(ran.timedOut ? " timeout" : "") \(AppLog.truncated(hook.command))")
            if ran.timedOut {
                outcome.notices.append("Hook timed out after \(Int(hook.timeout))s and was stopped: \(hook.command)")
                continue
            }
            if ran.exitCode == 2 {
                let reason = ran.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = reason.isEmpty ? "Blocked by a hook (\(hook.command))." : reason
                switch event {
                case .preToolUse, .userPromptSubmit:
                    outcome.blockReason = text
                    return outcome
                case .postToolUse:
                    outcome.context.append(text)
                case .stop:
                    break
                }
                continue
            }
            if ran.exitCode != 0 {
                let detail = ran.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome.notices.append("Hook failed (exit \(ran.exitCode)): \(hook.command)" + (detail.isEmpty ? "" : "\n\(String(detail.prefix(400)))"))
                continue
            }
            let parsed = interpret(stdout: ran.stdout, event: event)
            if let block = parsed.block, event == .preToolUse || event == .userPromptSubmit {
                outcome.blockReason = block
                return outcome
            }
            outcome.context += parsed.context
        }
        return outcome
    }

    /// Exit-0 output: JSON with a decision or context, or — for events where it means something —
    /// plain text taken as context.
    static func interpret(stdout: String, event: HookEvent) -> (block: String?, context: [String]) {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, []) }
        guard text.hasPrefix("{"), let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, event == .userPromptSubmit ? [text] : [])
        }
        let specific = object["hookSpecificOutput"] as? [String: Any]
        var block: String?
        if (object["decision"] as? String) == "block" {
            block = (object["reason"] as? String) ?? "Blocked by a hook."
        }
        if let decision = specific?["permissionDecision"] as? String, decision == "deny" {
            block = (specific?["permissionDecisionReason"] as? String) ?? (object["reason"] as? String) ?? "Blocked by a hook."
        }
        if (object["continue"] as? Bool) == false {
            block = (object["stopReason"] as? String) ?? block ?? "Stopped by a hook."
        }
        var context: [String] = []
        for source in [object, specific ?? [:]] {
            if let extra = source["additionalContext"] as? String, !extra.isEmpty { context.append(extra) }
        }
        return (block, context)
    }

    struct Ran: Sendable { var exitCode: Int32; var stdout: String; var stderr: String; var timedOut: Bool }

    static func execute(_ hook: HookCommand, stdin: Data, workspaceRoot: String) async -> Ran {
        var environment = ShellEnvironment.standard(custom: [:])
        environment["SWIFTOPENWORK_PROJECT_DIR"] = workspaceRoot
        environment["CLAUDE_PROJECT_DIR"] = workspaceRoot
        let ran = await SubprocessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", hook.command],
            cwd: workspaceRoot.isEmpty ? NSHomeDirectory() : workspaceRoot,
            environment: environment, stdin: stdin, timeout: hook.timeout, maxBytes: maxCapturedBytes
        )
        return Ran(exitCode: ran.exitCode, stdout: ran.stdout, stderr: ran.stderr, timedOut: ran.timedOut)
    }
}
