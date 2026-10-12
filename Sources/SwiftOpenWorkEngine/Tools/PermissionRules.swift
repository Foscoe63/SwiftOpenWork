import Foundation
import SwiftOpenWorkCore

public enum PermissionAction: String, Codable, Sendable, Equatable {
    case allow, ask, deny
}

/// One standing decision about a tool call: "always allow `git status*`", "never touch `.env`".
///
/// The four approval levels in the composer answer "how much do I trust the agent". They cannot
/// say "this command is fine, that one never", which is what people actually want after the third
/// prompt for `git status`. Rules sit on top of the level and decide individual calls.
public struct PermissionRule: Codable, Equatable, Sendable {
    /// Tool name, or a glob over it: `terminal_command`, `file_*`, `mcp__github__*`, `*`. Matched
    /// against the resolved built-in name and the name as the model spelled it.
    public var tool: String
    /// Glob over what the call acts on: the command for a shell tool, the path for a file tool,
    /// the URL for `fetch_url`. Absent means every call of the tool.
    public var pattern: String?
    public var action: PermissionAction
    /// Shown to the model when the rule denies a call.
    public var reason: String?

    public init(tool: String, pattern: String? = nil, action: PermissionAction, reason: String? = nil) {
        self.tool = tool
        self.pattern = pattern
        self.action = action
        self.reason = reason
    }
}

public struct PermissionVerdict: Sendable, Equatable {
    public var action: PermissionAction
    public var rule: PermissionRule

    /// What the model or the person is told.
    public var explanation: String {
        let scope = rule.pattern.map { "\(rule.tool)(\($0))" } ?? rule.tool
        if let reason = rule.reason, !reason.isEmpty { return "\(reason) (permission rule \(scope))" }
        switch action {
        case .deny: return "Denied by permission rule \(scope)."
        case .ask: return "Permission rule \(scope) asks before this call."
        case .allow: return "Allowed by permission rule \(scope)."
        }
    }
}

/// Rule files and the decision they give.
///
/// Rules live in `.swiftopenwork/permissions.json` in the workspace (reviewable, travels with the
/// checkout) and `~/.swiftopenwork/permissions.json` (yours everywhere). Both are read; order does
/// not matter, because the outcome is fixed by strength instead: **deny beats ask beats allow**.
/// A project file can therefore tighten what your global file allows, and cannot be loosened by a
/// later line.
///
/// ```json
/// { "allow": ["terminal_command(git status*)", "terminal_command(swift build*)"],
///   "ask":   ["terminal_command(git push*)"],
///   "deny":  ["file_*(**/.env*)", "terminal_command(rm -rf *)"] }
/// ```
/// or `{ "rules": [ { "tool": "terminal_command", "pattern": "git status*", "action": "allow" } ] }`.
///
/// Two limits keep a rule from being a loophole:
/// - An **allow** never applies to a shell command that chains, pipes, redirects or substitutes
///   (`git status; rm -rf ~`): that is a different command from the one the rule names.
/// - An allow does not lift the guards that are not about trusting the agent — secret files,
///   leaving plan mode and the fetch-site policy keep asking (see `AgentRunner.approvalReason`).
public enum PermissionRules {
    public static let relativePath = ".swiftopenwork/permissions.json"

    /// Tests point this somewhere empty so the machine's own rules cannot change their outcome.
    nonisolated(unsafe) public static var globalPathOverride: String?

    public static var globalPath: String {
        if let globalPathOverride { return globalPathOverride }
        return AppIdentity.homeDataDirectory.appendingPathComponent("permissions.json").path
    }

    public static func projectPath(workspaceRoot: String) -> String {
        (workspaceRoot as NSString).appendingPathComponent(relativePath)
    }

    // MARK: - Loading

    private struct Cached { var modified: Date?; var rules: [PermissionRule] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]

    /// Every rule that applies to this workspace. Cheap to call per tool call: a file is re-read
    /// only when its modification date moves.
    public static func load(workspaceRoot: String) -> [PermissionRule] {
        var paths = [globalPath]
        if !workspaceRoot.isEmpty { paths.append(projectPath(workspaceRoot: workspaceRoot)) }
        return paths.flatMap(rules(atPath:))
    }

    static func rules(atPath path: String) -> [PermissionRule] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[path], hit.modified == modified { return hit.rules }
        var parsed: [PermissionRule] = []
        if modified != nil, let data = FileManager.default.contents(atPath: path) {
            parsed = parse(data)
        }
        cache[path] = Cached(modified: modified, rules: parsed)
        return parsed
    }

    /// Lenient on purpose: a rules file somebody hand-edits should not silently stop working
    /// because of one bad entry. Unreadable entries are skipped, not fatal.
    public static func parse(_ data: Data) -> [PermissionRule] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rules: [PermissionRule] = []
        func addObjects(_ list: [Any]) {
            for case let object as [String: Any] in list {
                guard let tool = object["tool"] as? String, !tool.isEmpty,
                      let raw = object["action"] as? String, let action = PermissionAction(rawValue: raw.lowercased())
                else { continue }
                rules.append(PermissionRule(
                    tool: tool, pattern: (object["pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    action: action, reason: object["reason"] as? String
                ))
            }
        }
        if let list = root as? [Any] {
            addObjects(list)
        } else if let object = root as? [String: Any] {
            if let list = object["rules"] as? [Any] { addObjects(list) }
            for action in [PermissionAction.allow, .ask, .deny] {
                for case let entry as String in (object[action.rawValue] as? [Any]) ?? [] {
                    if let rule = shorthand(entry, action: action) { rules.append(rule) }
                }
            }
        }
        return rules
    }

    /// `tool(pattern)` or just `tool`.
    static func shorthand(_ entry: String, action: PermissionAction) -> PermissionRule? {
        let text = entry.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix(")"), let open = text.firstIndex(of: "(") {
            let tool = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            let pattern = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            guard !tool.isEmpty else { return nil }
            return PermissionRule(tool: tool, pattern: pattern.isEmpty ? nil : pattern, action: action)
        }
        return PermissionRule(tool: text, action: action)
    }

    // MARK: - Deciding

    /// The rule that decides this call, or nil when none applies and the approval level stands.
    public static func verdict(
        toolName: String,
        argumentsJson: String,
        workspaceRoot: String,
        rules: [PermissionRule]? = nil
    ) -> PermissionVerdict? {
        let rules = rules ?? load(workspaceRoot: workspaceRoot)
        guard !rules.isEmpty else { return nil }
        let canonical = ToolCallRepair.builtInCanonical(toolName)
        let names = Set([toolName, canonical].compactMap { $0 })
        let candidates = rules.filter { rule in
            names.contains { CodeSearch.matchSegment($0, pattern: rule.tool) }
        }
        guard !candidates.isEmpty else { return nil }

        let subjects = Self.subjects(
            canonical: canonical ?? toolName, argumentsJson: argumentsJson, workspaceRoot: workspaceRoot
        )
        var best: PermissionVerdict?
        for rule in candidates {
            guard matches(rule, subjects: subjects) else { continue }
            let strength = rank(rule.action)
            if best == nil || strength > rank(best!.action) { best = PermissionVerdict(action: rule.action, rule: rule) }
        }
        return best
    }

    private static func rank(_ action: PermissionAction) -> Int {
        switch action { case .allow: return 0; case .ask: return 1; case .deny: return 2 }
    }

    /// What a call acts on, in the form its patterns are written against.
    enum Subjects {
        case none
        case commands(whole: String, segments: [String], chained: Bool)
        case paths([String])
        case url(String)
    }

    static func subjects(canonical: String, argumentsJson: String, workspaceRoot: String) -> Subjects {
        guard let data = argumentsJson.data(using: .utf8),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .none }
        let args = ToolCallRepair.normalizeArguments(tool: canonical, raw)
        switch canonical {
        case "terminal_command", "run_command":
            guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { return .none }
            let split = splitShell(command)
            return .commands(whole: command, segments: split.segments, chained: split.chained)
        case "fetch_url":
            guard let url = (args["url"] as? String) ?? (args["href"] as? String) else { return .none }
            return .url(url.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            guard SubAgentToolPolicy.fileEditTools.contains(canonical)
                    || ["file_read", "read_file", "document_extract", "extract_document", "read_pdf_or_image"].contains(canonical)
            else { return .none }
            let paths = SubAgentToolPolicy.targetPaths(toolName: canonical, arguments: raw)
                + SubAgentToolPolicy.targetPaths(toolName: canonical, arguments: args)
            let relative = Set(paths.map { relativeToWorkspace($0, root: workspaceRoot) })
            return relative.isEmpty ? .none : .paths(Array(relative))
        }
    }

    private static func relativeToWorkspace(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        let absolute = path.hasPrefix("/") || path.hasPrefix("~") ? path : (root as NSString).appendingPathComponent(path)
        let resolved = ToolExecutionEngine.canonicalPath(absolute)
        let base = ToolExecutionEngine.canonicalPath(root)
        if resolved == base { return "." }
        if resolved.hasPrefix(base + "/") { return String(resolved.dropFirst(base.count + 1)) }
        return resolved
    }

    private static func matches(_ rule: PermissionRule, subjects: Subjects) -> Bool {
        // No pattern: every call of the tool.
        guard let pattern = rule.pattern?.trimmingCharacters(in: .whitespaces), !pattern.isEmpty, pattern != "*" else {
            return true
        }
        switch subjects {
        case .none:
            return false
        case let .commands(whole, segments, chained):
            if rule.action == .allow {
                // `git status; rm -rf ~` is not `git status`.
                return !chained && CodeSearch.matchSegment(whole, pattern: pattern)
            }
            // A deny or ask must catch the dangerous part wherever it hides in a chain.
            return CodeSearch.matchSegment(whole, pattern: pattern)
                || segments.contains { CodeSearch.matchSegment($0, pattern: pattern) }
        case let .paths(paths):
            let hit = { (path: String) in CodeSearch.matches(path: path, pattern: pattern) }
            // Allow only when every path is covered; deny and ask when any one is.
            return rule.action == .allow ? paths.allSatisfy(hit) : paths.contains(where: hit)
        case let .url(url):
            return CodeSearch.matchSegment(url, pattern: pattern)
        }
    }

    /// Pieces of a shell line, and whether it is more than one simple command. Quoting is not
    /// parsed: a quoted `;` makes the line count as chained, which only ever makes an allow
    /// stricter and a deny wider.
    static func splitShell(_ command: String) -> (segments: [String], chained: Bool) {
        var segments: [String] = []
        var current = ""
        var chained = false
        let characters = Array(command)
        var index = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }
        while index < characters.count {
            let c = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch c {
            case ";", "\n", "|", "&":
                chained = true
                flush()
                if (c == "|" || c == "&"), next == c { index += 1 }
            case "`", ">", "<":
                chained = true
                current.append(c)
            case "$" where next == "(":
                chained = true
                current.append(c)
            default:
                current.append(c)
            }
            index += 1
        }
        flush()
        return (segments, chained || segments.count > 1)
    }

    // MARK: - Writing

    /// Remember a decision. Appends to the workspace's own file, creating it; an identical rule is
    /// not added twice. Returns the rule written, or nil if nothing could be written.
    @discardableResult
    public static func remember(
        toolName: String,
        argumentsJson: String,
        action: PermissionAction = .allow,
        workspaceRoot: String
    ) -> PermissionRule? {
        guard !workspaceRoot.isEmpty, let rule = suggestedRule(toolName: toolName, argumentsJson: argumentsJson, action: action, workspaceRoot: workspaceRoot)
        else { return nil }
        let path = projectPath(workspaceRoot: workspaceRoot)
        var existing = rules(atPath: path)
        guard !existing.contains(rule) else { return rule }
        existing.append(rule)
        let objects: [[String: Any]] = existing.map { rule in
            var object: [String: Any] = ["tool": rule.tool, "action": rule.action.rawValue]
            if let pattern = rule.pattern { object["pattern"] = pattern }
            if let reason = rule.reason { object["reason"] = reason }
            return object
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["rules": objects], options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return nil }
        return rule
    }

    /// The narrowest rule that covers this call and its obvious repeats: for a shell command the
    /// first word(s) of a simple command (`git status -sb` → `git status*`), for a file tool the
    /// tool alone, since "always allow edits to this one path" is rarely what anyone means.
    public static func suggestedRule(
        toolName: String, argumentsJson: String, action: PermissionAction, workspaceRoot: String
    ) -> PermissionRule? {
        let canonical = ToolCallRepair.builtInCanonical(toolName) ?? toolName
        if case let .commands(whole, _, chained) = subjects(canonical: canonical, argumentsJson: argumentsJson, workspaceRoot: workspaceRoot) {
            // A chained line has no narrow, honest rule: it would have to be the exact line.
            if chained { return PermissionRule(tool: canonical, pattern: whole, action: action) }
            // A prefix rule on a program that destroys, escalates or reaches out would approve every
            // use of it, so those are remembered as the exact line only.
            let broad: Set<String> = ["rm", "sudo", "dd", "mv", "chmod", "chown", "kill", "killall", "curl", "wget",
                                      "ssh", "scp", "sh", "bash", "zsh", "eval", "exec", "xargs", "find", "osascript", "open"]
            if let first = whole.split(separator: " ").first, broad.contains(String(first)) {
                return PermissionRule(tool: canonical, pattern: whole, action: action)
            }
            let words = whole.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Subcommand tools (`git status`, `swift build`) get two words; anything else, one.
            let twoWordTools: Set<String> = ["git", "swift", "npm", "pnpm", "yarn", "cargo", "go", "xcodebuild", "make", "docker", "brew", "gh"]
            let keep = words.first.map { twoWordTools.contains($0) && words.count > 1 && !words[1].hasPrefix("-") ? 2 : 1 } ?? 1
            let prefix = words.prefix(keep).joined(separator: " ")
            return PermissionRule(tool: canonical, pattern: words.count > keep ? prefix + " *" : prefix, action: action)
        }
        if MCPNamespacedTool.isNamespaced(toolName) { return PermissionRule(tool: toolName, action: action) }
        return PermissionRule(tool: canonical, action: action)
    }
}
