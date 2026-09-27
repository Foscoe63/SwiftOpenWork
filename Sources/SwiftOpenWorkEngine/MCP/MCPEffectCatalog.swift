import Foundation
import SwiftOpenWorkCore

public enum MCPEffect: String, Codable, Sendable {
    case read
    case write
}

/// Fail-closed read/write classification for MCP tools.
///
/// A tool counts as a read only when it is advertised by a server we have a table for and is
/// absent from that table's write list, or when its exact name is on the universal read list.
/// Everything else — unknown servers, unadvertised names, anything ambiguous — is a write.
///
/// This replaces prefix matching (`get_`, `list_`, `search`), which classified
/// `get_or_create_repository` and `search_and_replace` as reads.
public enum MCPEffectCatalog: Sendable {
    public struct Entry: Sendable {
        public var key: String
        /// Tools on this server that mutate state. Everything else it advertises is a read.
        public var writeTools: Set<String>
        public var nameHints: [String]
        public var commandHints: [String]

        public init(key: String, writeTools: Set<String>, nameHints: [String], commandHints: [String] = []) {
            self.key = key
            self.writeTools = writeTools
            self.nameHints = nameHints
            self.commandHints = commandHints
        }
    }

    /// Tool names that are reads on every server. Exact matches only — never prefixes.
    public static let universalReadTools: Set<String> = [
        "get_tool_definitions", "list_tools", "tools_list", "list_resources",
        "read_resource", "list_prompts", "get_prompt",
    ]

    /// Verbs that make a tool a write no matter what the per-server table says.
    ///
    /// The tables below are a snapshot; servers add tools faster than the tables are updated, and
    /// "absent from the write list" would otherwise quietly mean "safe". These are matched as whole
    /// name tokens, not substrings, so `list_commits` stays a read while `commit_changes` does not.
    public static let mutatingVerbs: Set<String> = [
        "create", "update", "delete", "remove", "write", "edit", "modify", "patch",
        "send", "post", "put", "insert", "upload", "publish", "submit",
        "replace", "rename", "move", "copy", "merge", "push", "commit", "revert",
        "archive", "compress", "extract", "trash", "purge", "clear", "reset", "restore",
        "install", "uninstall", "execute", "exec", "run", "invoke", "kill", "terminate",
        "grant", "revoke", "approve", "reject", "assign", "unassign", "respond", "reply",
        "forward", "schedule", "cancel", "close", "reopen", "lock", "unlock",
        "enable", "disable", "start", "stop", "restart", "sync",
        "drop", "truncate", "alter", "set",
        "click", "type", "press", "drag", "tap",
        // Verbs that were missing: a tool named `add_sub_issue` or `save_note` has none of the
        // words above, so on a server with a table it was read as "absent from the write list,
        // therefore a read".
        "add", "append", "save", "share", "deploy", "trigger", "dispatch", "import", "upsert",
        "mark", "invite", "apply", "transfer", "star", "unstar", "subscribe", "unsubscribe",
        "follow", "unfollow", "fork", "attach", "detach", "dismiss", "accept", "decline",
        "notify", "remember", "store", "retain", "pay", "buy",
    ]

    /// Verbs that are also ordinary nouns, so `get_commit`, `list_workflow_run` and
    /// `get_merge_request` are not mutations. They count only when the name does not begin with
    /// a read word — and never in a name that joins two actions (`get_or_create_…`).
    static let nounLikeVerbs: Set<String> = [
        "commit", "run", "close", "lock", "start", "stop", "sync", "schedule", "merge",
        "push", "post", "put", "copy", "move", "type", "click", "drag", "tap", "press",
    ]

    static let readLeadWords: Set<String> = [
        "get", "list", "search", "read", "fetch", "find", "show", "describe", "view", "count",
        "check", "query", "lookup", "inspect",
    ]

    /// Lowercased word tokens of a tool name, splitting on separators *and* camelCase, so both
    /// `create_jira_issue` and `createJiraIssue` yield `create`.
    public static func nameTokens(_ toolName: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
        }

        for char in toolName {
            if char.isLetter || char.isNumber {
                // A capital after a lowercase starts a new word (createIssue → create, Issue).
                if char.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                    flush()
                }
                current.append(char)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// True when any token of the name is a mutating verb.
    public static func nameSuggestsWrite(_ toolName: String) -> Bool {
        let tokens = nameTokens(toolName)
        // "get_commit": a read word up front and no second action in the name — nouns that are
        // also verbs do not turn it into a write. Anything joined ("get_or_create", "list_and_
        // archive") is judged on every word.
        if let first = tokens.first, readLeadWords.contains(first),
           !tokens.contains("and"), !tokens.contains("or") {
            return tokens.dropFirst().contains { mutatingVerbs.contains($0) && !nounLikeVerbs.contains($0) }
        }
        return tokens.contains { mutatingVerbs.contains($0) }
    }

    public static let entries: [Entry] = [
        Entry(
            key: "github",
            writeTools: [
                "create_or_update_file", "create_repository", "fork_repository", "push_files",
                "create_issue", "update_issue", "add_issue_comment", "create_pull_request",
                "update_pull_request", "merge_pull_request", "create_pull_request_review",
                "add_pull_request_review_comment", "request_copilot_review", "create_gist",
                "update_gist", "delete_file", "create_branch", "update_pull_request_branch",
                "submit_pending_pull_request_review", "add_comment_to_pending_review",
                "delete_pending_pull_request_review", "assign_copilot_to_issue",
            ],
            nameHints: ["github"],
            commandHints: ["github-mcp", "github_mcp", "server-github"]
        ),
        Entry(
            key: "filesystem",
            writeTools: [
                "write_file", "edit_file", "multi_edit", "create_directory", "move_file", "delete_file",
                "fast_write_file", "fast_large_write_file", "fast_edit_block", "fast_edit_blocks",
                "fast_edit_multiple_blocks", "fast_safe_edit", "fast_create_directory",
                "fast_delete_file", "fast_move_file", "fast_copy_file", "fast_sync_directories",
                "fast_compress_files", "fast_extract_archive", "fast_batch_file_operations",
            ],
            nameHints: ["filesystem", "fast-filesystem", "file-system", "files"],
            commandHints: ["server-filesystem", "fast-filesystem"]
        ),
        Entry(
            key: "atlassian",
            writeTools: [
                "createJiraIssue", "editJiraIssue", "transitionJiraIssue", "addCommentToJiraIssue",
                "addWorklogToJiraIssue", "createConfluencePage", "updateConfluencePage",
                "createConfluenceFooterComment", "createConfluenceInlineComment",
            ],
            nameHints: ["atlassian", "jira", "confluence"],
            commandHints: ["atlassian"]
        ),
        Entry(
            key: "slack",
            writeTools: [
                "slack_send_message", "slack_send_message_draft", "slack_schedule_message",
                "slack_add_reaction", "slack_create_conversation", "slack_create_canvas",
                "slack_update_canvas", "slack_post_message", "slack_reply_to_thread",
            ],
            nameHints: ["slack"],
            commandHints: ["slack"]
        ),
        Entry(
            key: "gmail",
            writeTools: [
                "send_message", "create_draft", "update_draft", "reply", "forward",
                "trash_message", "trash_thread", "untrash_message", "untrash_thread",
                "delete_label", "create_label", "update_label", "label_message", "label_thread",
                "unlabel_message", "unlabel_thread", "update_message_labels",
                "mark_message_spam", "mark_thread_spam",
            ],
            nameHints: ["gmail", "google-mail"],
            commandHints: ["gmail"]
        ),
        Entry(
            key: "calendar",
            writeTools: [
                "create_event", "update_event", "delete_event", "respond_to_event",
                "calendar_create_event", "calendar_update_event", "calendar_cancel_event",
            ],
            nameHints: ["calendar", "gcal"],
            commandHints: ["calendar"]
        ),
        Entry(
            key: "macuse",
            writeTools: [
                // MacUse exposes meta-tools; nested targets are classified separately by
                // `classifyNested`. These are the directly-callable mutating ones.
                "computer_use_click", "computer_use_type_text", "computer_use_key",
                "mail_send_message", "mail_delete_message", "mail_move_message",
                "messages_send_message", "notes_create_note", "notes_update_note",
                "notes_delete_note", "reminders_create_reminder", "reminders_update_reminder",
                "reminders_delete_reminder", "calendar_create_event", "calendar_cancel_event",
                "contacts_create_contact", "shortcuts_run",
            ],
            nameHints: ["macuse", "mac-use", "mac_use"],
            commandHints: ["macuse"]
        ),
        Entry(
            key: "search",
            // Search/fetch servers are read-only surfaces; nothing they expose mutates state.
            writeTools: [],
            nameHints: ["ddg", "duckduckgo", "brave-search", "firecrawl", "context7", "codegraph"],
            commandHints: ["ddg-search", "firecrawl", "context7", "codegraph"]
        ),
        Entry(
            key: "memory",
            writeTools: [
                "create_entities", "create_relations", "add_observations", "delete_entities",
                "delete_observations", "delete_relations",
            ],
            nameHints: ["memory", "knowledge-graph"],
            commandHints: ["server-memory"]
        ),
        Entry(
            key: "database",
            writeTools: [
                "write_query", "create_table", "alter_table", "drop_table", "execute",
                "insert", "update", "delete",
            ],
            nameHints: ["sqlite", "postgres", "postgresql", "mysql"],
            commandHints: ["server-postgres", "server-sqlite"]
        ),
    ]

    /// Hints so common that a substring hit is more likely a coincidence than a match — a server
    /// called "Profiles" is not a filesystem. These must match as whole words.
    private static let wholeWordHints: Set<String> = ["files", "memory", "calendar"]

    private static func hint(_ hint: String, matches text: String) -> Bool {
        guard wholeWordHints.contains(hint) else { return text.contains(hint) }
        func words(_ raw: String) -> String {
            "-" + raw.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + "-"
        }
        return words(text).contains("-\(hint)-")
    }

    public static func entry(for server: MCPServerConfig) -> Entry? {
        let name = server.name.lowercased()
        let command = ([server.command] + server.args).joined(separator: " ").lowercased()
        let url = server.url.lowercased()
        return entries.first { entry in
            entry.nameHints.contains { hint($0, matches: name) || hint($0, matches: url) }
                || entry.commandHints.contains { command.contains($0) }
        }
    }

    /// Advertised by a known server and absent from its write list → read. Everything else is a write.
    public static func classify(
        server: MCPServerConfig?,
        toolName: String,
        advertised: Bool
    ) -> MCPEffect {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .write }
        if universalReadTools.contains(trimmed) { return .read }
        if nameSuggestsWrite(trimmed) { return .write }
        guard advertised else { return .write }
        guard let server, let entry = entry(for: server) else { return .write }
        return entry.writeTools.contains(trimmed) ? .write : .read
    }

    /// Classify a meta-tool call (`call_tool_by_name`) by the nested target it dispatches to.
    ///
    /// The wrapper itself tells you nothing — `call_tool_by_name` is a read when it lists mailboxes
    /// and a write when it sends mail — so the nested name is what gets classified. An unreadable
    /// or absent nested name is a write.
    public static func classifyNested(
        server: MCPServerConfig?,
        nestedToolName: String?
    ) -> MCPEffect {
        guard let nested = nestedToolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nested.isEmpty else {
            return .write
        }
        // A nested name is by definition not in the server's advertised list (only the meta-tool
        // is), so classify it against the server's write table directly.
        if universalReadTools.contains(nested) { return .read }
        if nameSuggestsWrite(nested) { return .write }
        guard let server, let entry = entry(for: server) else { return .write }
        return entry.writeTools.contains(nested) ? .write : .read
    }
}
