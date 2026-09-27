import Foundation
import SwiftOpenWorkCore

/// What each seeded agent should be able to do, matched to its role.
///
/// `SubAgentExecutor.toolSet` honours `allowedToolIds` for sub-agents (empty = everything), so
/// these lists are real restrictions: the reviewer cannot edit, the researcher cannot run a shell.
/// The lead agent is never filtered by its list; it is populated so the editor shows its intent.
/// `mcp_<server>` entries only take effect once that server is enabled in Settings.
public enum AgentRoleProfiles {

    static let readCode = [
        "file_read", "file_list", "grep", "glob", "find_symbol", "document_symbols",
        "find_references", "go_to_definition", "symbol_info", "call_hierarchy", "code_diagnostics",
    ]

    public static let toolsByAgentId: [String: [String]] = [
        "lead-assistant": [
            "agent_spawn", "agent_message", "todo_write", "ask_user", "exit_plan_mode",
            "file_read", "file_list", "grep", "glob", "workspace_semantic_search",
            "memory_store", "memory_recall", "get_current_date",
            "git_status", "git_diff", "git_log", "changed_files", "build_project", "run_tests",
            "revert_changes", "mcp_mcp-memory", "mcp_mcp-git",
        ],
        "coder-agent": readCode + [
            "file_write", "edit_file", "multi_edit", "file_copy", "file_move", "rename_symbol",
            "setup_xcode_language_server", "build_project", "run_tests", "terminal_command",
            "run_app", "quit_app", "screenshot_window", "accessibility_tree",
            "preview_start", "preview_check", "preview_logs", "preview_stop",
            "git_status", "git_diff", "git_log", "changed_files", "revert_changes",
            "worktree_create", "worktree_list", "git_commit",
            "mcp_mcp-filesystem", "mcp_mcp-git",
        ],
        "research-agent": [
            "web_search", "fetch_url", "document_extract", "image_analyze", "mlx_vision_describe",
            "workspace_semantic_search", "file_read", "file_list", "grep", "glob",
            "find_symbol", "document_symbols", "git_log",
            "memory_store", "memory_recall", "get_current_date", "calculator",
            "mcp_mcp-fetch", "mcp_mcp-memory",
        ],
        "reviewer-agent": readCode + [
            "git_diff", "git_status", "git_log", "changed_files",
            "build_project", "run_tests", "todo_write", "mcp_mcp-git",
        ],
        "architect-agent": [
            "file_read", "file_list", "glob", "grep", "workspace_semantic_search",
            "find_symbol", "document_symbols", "call_hierarchy", "find_references", "git_log",
            "web_search", "fetch_url",
            "agent_spawn", "memory_store", "memory_recall", "todo_write", "ask_user",
            "mcp_mcp-memory", "mcp_mcp-filesystem",
        ],
    ]

    /// Names a mix-up left on the wrong agent, and what the seed calls them.
    static let swappedNames: [String: (wrong: String, right: String)] = [
        "coder-agent": ("Reviewer-Agent", "Software Engineer Agent"),
        "reviewer-agent": ("Coder-Agent", "Code Review & Quality Critic"),
        "research-agent": ("Reasearch-Agent", "Deep Research Agent"),
    ]

    /// Applies the profiles to an existing install: fixes the swapped seed names and fills in an
    /// allowlist only where it is empty, so one a user set themselves is left alone.
    /// Returns true when anything changed.
    @discardableResult
    public static func migrate(_ agents: inout [Agent]) -> Bool {
        var changed = false
        for i in agents.indices where agents[i].isBuiltIn {
            let id = agents[i].id
            if let fix = swappedNames[id], agents[i].name == fix.wrong {
                agents[i].name = fix.right
                changed = true
            }
            if agents[i].allowedToolIds.isEmpty, let tools = toolsByAgentId[id] {
                agents[i].allowedToolIds = tools
                changed = true
            }
        }
        return changed
    }

    // MARK: - Skills

    /// Skills are global (every enabled one is listed in every agent's prompt), so each is kept
    /// short and phrased so it only matters to the agent doing that kind of work.
    public static var extraSkills: [Skill] {
        [
            Skill(
                id: "task-delegation-skill",
                name: "Task Planning & Delegation",
                description: "Break a goal into independent steps and hand each to the right sub-agent.",
                category: "Orchestration",
                content: """
                # Task Planning & Delegation
                1. Split the goal into steps; run independent steps in parallel.
                2. Send code changes to the Coder, investigation to the Researcher, structure questions to the Architect, verification to the Reviewer.
                3. Give each sub-agent a self-contained objective and a definition of done.
                4. Check the diff, build and tests yourself before reporting success.
                """,
                source: .builtIn
            ),
            Skill(
                id: "swift-conventions-skill",
                name: "Swift & SwiftUI Conventions",
                description: "Idiomatic Swift: value types, structured concurrency, @Observable, small views.",
                category: "Engineering",
                content: """
                # Swift & SwiftUI Conventions
                - Prefer structs and protocols; mark UI state @MainActor.
                - Use async/await and actors over callbacks and locks; keep types Sendable.
                - Keep SwiftUI views small; stable identity in ForEach; no work in `body`.
                - Match the surrounding code's naming and comment style.
                """,
                source: .builtIn
            ),
            Skill(
                id: "architecture-decision-skill",
                name: "Architecture Decision Records",
                description: "Record design choices with context, options, trade-offs and consequences.",
                category: "Architecture",
                content: """
                # Architecture Decision Records
                For each significant decision write: Context, Options considered, Decision, Consequences (good and bad), and what would make you revisit it.
                Define module boundaries and API contracts (inputs, outputs, errors) before implementation.
                """,
                source: .builtIn
            ),
            Skill(
                id: "source-evaluation-skill",
                name: "Source Evaluation & Citation",
                description: "Prefer primary sources, cross-check claims, cite every fact.",
                category: "Research",
                content: """
                # Source Evaluation & Citation
                1. Prefer official docs and primary sources over blogs and forums.
                2. Cross-check important claims across two sources; note the date.
                3. Cite the URL or file path for every fact, and say plainly what you could not verify.
                """,
                source: .builtIn
            ),
        ]
    }

    /// Adds `extraSkills` that are not there yet. Returns true when anything was added.
    @discardableResult
    public static func addMissingSkills(to skills: inout [Skill]) -> Bool {
        let have = Set(skills.map(\.id))
        let missing = extraSkills.filter { !have.contains($0.id) }
        skills.append(contentsOf: missing)
        return !missing.isEmpty
    }
}
