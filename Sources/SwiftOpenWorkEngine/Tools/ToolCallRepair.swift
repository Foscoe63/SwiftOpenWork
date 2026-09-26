import Foundation

/// The single place that turns what a model *wrote* into what a tool *accepts*.
///
/// Models — local ones especially — rarely emit the exact tool name and argument keys in our
/// schema. Every one of those near-misses used to be handled (or not) ad hoc at whichever `case`
/// in the dispatcher happened to notice it, which is how `read` fell through to MCP and answered
/// "No MCP servers are enabled" to a file read. Three rules live here instead:
///
/// 1. **One alias table.** Both the dispatcher and the agent loop's policy checks resolve names
///    through `canonicalName`, so they cannot disagree about what a tool is called.
/// 2. **Repair, don't reject, when the intent is unambiguous.** A `cmd` for `command`, `"true"`
///    for `true`, `file_path` for `path`, `file://` in front of a path — fixed silently.
/// 3. **When it can't be repaired, say what to do.** An unknown tool names the closest real ones.
public enum ToolCallRepair {

    // MARK: - Names

    /// Every built-in tool the dispatcher handles, by canonical name.
    public static let builtInNames: [String] = [
        "file_read", "file_write", "edit_file", "multi_edit", "file_list", "file_copy", "file_move",
        "file_delete", "glob", "grep", "find_symbol", "terminal_command", "build_project", "run_tests",
        "git_status", "git_diff", "git_log", "git_commit", "changed_files", "revert_changes",
        "rename_symbol", "go_to_definition", "find_references", "symbol_info", "call_hierarchy",
        "code_diagnostics", "document_symbols", "setup_xcode_language_server", "fetch_url",
        "web_search", "ask_user", "exit_plan_mode", "todo_write", "calculator", "get_current_date",
        "document_extract", "workspace_semantic_search", "generate_image", "mlx_vision_describe",
        "quit_app", "worktree_create", "worktree_list", "worktree_remove", "screenshot_window",
        "accessibility_tree", "run_app", "preview_start", "preview_check", "preview_logs",
        "preview_stop", "agent_spawn", "agent_message", "memory_store", "memory_recall", "mcp_call",
        "gmail_list", "google_calendar_list",
    ]

    /// First entry is the canonical name; the rest are spellings that resolve to it.
    private static let aliasGroups: [[String]] = [
        ["file_read", "read_file", "read", "cat", "view", "view_file", "open_file", "read_text_file", "get_file_contents"],
        ["file_write", "write_file", "create_file", "save_file", "write", "write_to_file", "create", "overwrite_file"],
        ["edit_file", "file_edit", "edit", "str_replace", "replace_in_file", "edit_block", "apply_edit"],
        ["multi_edit", "edit_file_multi", "multiedit", "multi_edit_file", "edit_multiple"],
        ["find_symbol", "symbol_search"],
        ["grep", "search_code", "code_search", "search", "ripgrep", "rg", "text_search", "find_in_files"],
        ["glob", "find_files", "find", "glob_files", "file_search", "find_file"],
        ["file_list", "list_files", "list_directory", "ls", "dir", "list_dir", "listdir", "list_folder"],
        ["file_copy", "copy_file", "cp"],
        ["file_move", "move_file", "mv", "rename_file"],
        ["file_delete", "delete_file", "rm", "delete", "remove", "remove_file", "unlink"],
        ["terminal_command", "run_command", "bash", "shell", "sh", "zsh", "run", "exec", "execute",
         "execute_command", "run_shell_command", "run_terminal_cmd", "run_terminal_command", "terminal"],
        ["build_project", "build", "compile"],
        ["run_tests", "test", "run_test"],
        ["fetch_url", "fetch", "web_fetch", "http_get", "get_url", "open_url"],
        ["web_search", "search_web", "internet_search"],
        ["todo_write", "todo", "todowrite", "update_todos", "todo_list"],
        ["calculator", "calc", "calculate"],
        ["get_current_date", "get_date", "current_date", "date"],
        ["document_extract", "extract_document", "read_pdf_or_image"],
        ["workspace_semantic_search", "search_workspace"],
        ["screenshot_window", "screenshot_app"],
        ["accessibility_tree", "ui_tree", "inspect_window"],
        ["run_app", "launch_app"],
        ["mcp_call", "call_mcp_tool"],
        ["mlx_vision_describe", "image_analyze"],
    ]

    private static let aliasMap: [String: String] = {
        var map: [String: String] = [:]
        for group in aliasGroups {
            for alias in group.dropFirst() { map[alias] = group[0] }
        }
        return map
    }()

    private static let builtInSet = Set(builtInNames)

    /// Prefixes some models put in front of a tool name (`functions.read_file`).
    private static let wrapperPrefixes = ["functions.", "function.", "default_api.", "tools.", "tool."]

    /// One name per tool, whichever alias the model used. A name that is not a built-in (an MCP
    /// tool, say) is returned lowercased and otherwise untouched.
    public static func canonicalName(_ raw: String) -> String {
        let lower = stripped(raw).lowercased()
        return aliasMap[lower] ?? lower
    }

    /// The name to dispatch on. Differs from `canonicalName` in one way: a name an enabled MCP
    /// server advertises itself is left alone, so a server's own `read` or `search` still wins
    /// over our loose alias for it. Names that are already built-in spellings are not affected —
    /// the dispatcher has always claimed those.
    public static func resolve(_ raw: String, mcpAdvertised: Set<String>) -> String {
        let canonical = canonicalName(raw)
        if let target = aliasMap[raw.lowercased()] ?? aliasMap[stripped(raw).lowercased()] {
            let isLooseAlias = !dispatcherClaimed.contains(stripped(raw).lowercased())
            if isLooseAlias, mcpAdvertised.contains(raw) || mcpAdvertised.contains(stripped(raw)) { return raw }
            return target
        }
        // Not an alias: only rewrite when it is a built-in in different case / wrapped. Anything
        // else (an MCP tool with capitals, say) is passed through exactly as the model sent it.
        if builtInSet.contains(canonical), canonical != raw { return canonical }
        return raw
    }

    /// The built-in this name means, or nil when it isn't one (an MCP tool, an unknown name).
    ///
    /// Anything that gates on tool *identity* — approval prompts, plan mode, sandbox policy — must
    /// go through this, not compare raw strings: the dispatcher resolves `delete`, `bash`, `write`
    /// and the rest to real tools, so a check that only knows the canonical spelling is a check the
    /// model can walk around by choosing another one.
    public static func builtInCanonical(_ raw: String) -> String? {
        let lower = stripped(raw).lowercased()
        if let target = aliasMap[lower] { return target }
        return builtInSet.contains(lower) ? lower : nil
    }

    /// Tools plan mode must not run — everything that writes, deletes, launches or shells out.
    public static let planModeBlocked: Set<String> = [
        "file_write", "file_delete", "file_move", "file_copy", "edit_file", "multi_edit",
        "rename_symbol", "preview_start", "run_app", "git_commit", "worktree_create",
        "worktree_remove", "setup_xcode_language_server", "terminal_command", "mcp_call",
        "revert_changes",
    ]

    public static func isBlockedInPlanMode(_ raw: String) -> Bool {
        guard let canonical = builtInCanonical(raw) else { return false }
        return planModeBlocked.contains(canonical)
    }

    private static func stripped(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in wrapperPrefixes where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }

    /// Spellings the dispatcher handled before the alias table grew; they keep priority over MCP.
    private static let dispatcherClaimed: Set<String> = [
        "read_file", "write_file", "create_file", "save_file", "file_edit", "edit_file_multi",
        "symbol_search", "search_code", "code_search", "find_files", "list_files", "list_directory",
        "ls", "dir", "copy_file", "cp", "move_file", "mv", "delete_file", "rm", "run_command",
        "get_date", "current_date", "date", "extract_document", "read_pdf_or_image", "search_workspace",
        "screenshot_app", "ui_tree", "inspect_window", "launch_app", "call_mcp_tool", "image_analyze",
    ]

    // MARK: - Unknown tools

    /// What to tell a model that called a tool we don't have. Names the nearest real tools so the
    /// next call can be right, instead of an MCP-flavoured error that has nothing to do with it.
    public static func unknownToolMessage(_ raw: String, mcpServerSummary: String?) -> String {
        let suggestions = nearestBuiltIns(to: canonicalName(raw))
        var message = "There is no tool named `\(raw)`. Nothing was executed."
        if !suggestions.isEmpty {
            message += " Did you mean: " + suggestions.map { "`\($0)`" }.joined(separator: ", ") + "?"
        }
        message += " Built-in tools include: file_read, edit_file, multi_edit, file_write, grep, glob, file_list, terminal_command, build_project."
        if let servers = mcpServerSummary {
            message += " Enabled MCP servers: \(servers) (their tools are named mcp__<serverId>__<tool>)."
        }
        return message
    }

    public static func nearestBuiltIns(to name: String, limit: Int = 3) -> [String] {
        guard !name.isEmpty else { return [] }
        let scored: [(String, Int)] = builtInNames.compactMap { candidate in
            if candidate.contains(name) || name.contains(candidate) { return (candidate, 0) }
            let d = editDistance(name, candidate)
            return d <= max(2, name.count / 3) ? (candidate, d) : nil
        }
        return scored.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.prefix(limit).map(\.0)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: - Arguments

    /// Argument keys a model may use in place of ours, by canonical tool. Applied only when our
    /// key is absent, so a correct call is never touched.
    private static let keyAliases: [String: [String: [String]]] = [
        "file_read": ["path": ["file_path", "filePath", "filepath", "filename", "file", "target_file", "absolute_path", "file_name"]],
        "file_write": [
            "path": ["file_path", "filePath", "filepath", "filename", "file", "target_file", "absolute_path", "file_name"],
            "content": ["contents", "text", "file_text", "file_content", "body", "data"],
        ],
        "edit_file": [
            "path": ["file_path", "filePath", "filepath", "filename", "file", "target_file", "absolute_path", "file_name"],
            "old_string": ["oldString", "old_str", "old_text", "oldText", "old", "search", "find", "target_string"],
            "new_string": ["newString", "new_str", "new_text", "newText", "new", "replace", "replacement", "replace_with"],
            "replace_all": ["replaceAll", "all", "global"],
        ],
        "multi_edit": ["path": ["file_path", "filePath", "filepath", "filename", "file", "target_file", "absolute_path"], "edits": ["changes", "replacements"]],
        "file_delete": ["path": ["file_path", "filePath", "filepath", "filename", "file", "target_file"]],
        "file_list": ["path": ["dir", "directory", "folder", "dir_path", "directory_path", "file_path", "relative_path"]],
        "file_copy": [
            "source": ["src", "from", "source_path", "source_file", "path"],
            "destination": ["dst", "dest", "to", "target", "destination_path", "target_path"],
        ],
        "file_move": [
            "source": ["src", "from", "source_path", "source_file", "path"],
            "destination": ["dst", "dest", "to", "target", "destination_path", "target_path"],
        ],
        "terminal_command": ["command": ["cmd", "script", "shell_command", "bash_command", "commandLine", "command_line", "input"]],
        "grep": ["pattern": ["query", "regex", "search", "text", "regexp", "search_term"]],
        "glob": ["pattern": ["glob", "glob_pattern", "file_pattern", "name", "query"]],
        "fetch_url": ["url": ["href", "link", "uri"]],
        "web_search": ["query": ["q", "search_query", "text"]],
    ]

    /// Keys whose value is a boolean flag; a model sending `"true"` meant `true`.
    private static let boolKeys: Set<String> = [
        "replace_all", "case_insensitive", "ignore_case", "staged", "dry_run", "force", "keep_running",
        "only_failing", "failed_only", "include_declaration", "run_in_background", "build",
    ]

    /// Keys holding a filesystem path that should not carry quotes, a `file://` scheme or stray
    /// whitespace.
    private static let pathKeys: Set<String> = ["path", "source", "destination", "cwd", "worktree_path"]

    /// `arguments` with the model's near-misses repaired. Pure: same input, same output, and a
    /// call that was already correct comes back equal.
    public static func normalizeArguments(tool canonical: String, _ arguments: [String: Any]) -> [String: Any] {
        // MCP tools and anything else we don't own keep their arguments exactly as sent.
        guard builtInSet.contains(canonical) else { return arguments }
        var dict = arguments

        // Key aliases — fill ours from theirs, only when ours is missing or empty.
        for (key, alternatives) in keyAliases[canonical] ?? [:] {
            if let existing = dict[key], !isEmptyString(existing) { continue }
            for alt in alternatives {
                if let value = dict[alt], !isEmptyString(value) {
                    dict[key] = value
                    break
                }
            }
        }

        // "true"/"false" → Bool.
        for key in boolKeys {
            if let s = dict[key] as? String {
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "yes", "1": dict[key] = true
                case "false", "no", "0": dict[key] = false
                default: break
                }
            }
        }

        // start_line/end_line → offset/limit for reads.
        if canonical == "file_read", dict["limit"] == nil, dict["max_lines"] == nil,
           let start = intValue(dict["offset"]) ?? intValue(dict["start_line"]) ?? intValue(dict["startLine"]),
           let end = intValue(dict["end_line"]) ?? intValue(dict["endLine"]), end >= start {
            dict["limit"] = end - start + 1
        }

        // `file_read` numbers its lines ("1806<TAB>code"); models paste that gutter into
        // old_string, which can never match the file.
        if canonical == "edit_file" {
            for key in ["old_string", "new_string"] {
                if let text = dict[key] as? String { dict[key] = stripLineNumberGutter(text) }
            }
        }

        // Path hygiene.
        for key in pathKeys {
            if let s = dict[key] as? String {
                dict[key] = cleanPath(s)
            }
        }
        return dict
    }

    /// Remove a `file_read` line-number gutter (`<digits><TAB>`) when *every* non-empty line has
    /// one. A tab straight after leading digits on each line is not something source code does, so
    /// this only fires on pasted read output; anything else comes back unchanged.
    public static func stripLineNumberGutter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return text }
        func gutterEnd(_ line: String) -> String.Index? {
            var i = line.startIndex
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            let digitsStart = i
            while i < line.endIndex, line[i].isASCII, line[i].isNumber { i = line.index(after: i) }
            guard i > digitsStart, i < line.endIndex, line[i] == "\t" else { return nil }
            return line.index(after: i)
        }
        guard nonEmpty.allSatisfy({ gutterEnd($0) != nil }) else { return text }
        return lines.map { line in gutterEnd(line).map { String(line[$0...]) } ?? line }.joined(separator: "\n")
    }

    public static func cleanPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespacesAndNewlines))
        if s.lowercased().hasPrefix("file://") {
            s = String(s.dropFirst("file://".count))
            s = s.removingPercentEncoding ?? s
        }
        if s.hasPrefix("~") { s = (s as NSString).expandingTildeInPath }
        return s
    }

    private static func isEmptyString(_ value: Any) -> Bool {
        (value as? String)?.isEmpty ?? false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d.isFinite, d == d.rounded() { return Int(d) }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite, d == d.rounded() { return Int(d) }
        }
        return nil
    }
}
