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

    static let baseToolsByAgentId: [String: [String]] = [
        "lead-assistant": [
            "agent_spawn", "agent_message", "todo_write", "ask_user", "exit_plan_mode",
            "file_read", "file_list", "grep", "glob", "workspace_semantic_search",
            "get_current_date",
            "git_status", "git_diff", "git_log", "changed_files", "build_project", "run_tests",
            "revert_changes", "worktree_list", "worktree_merge", "mcp_mcp-git",
        ],
        "coder-agent": readCode + [
            "file_write", "edit_file", "multi_edit", "file_copy", "file_move", "rename_symbol",
            "setup_xcode_language_server", "build_project", "run_tests", "terminal_command", "send_input",
            "run_app", "quit_app", "screenshot_window", "accessibility_tree",
            "preview_start", "preview_check", "preview_logs", "preview_stop",
            "git_status", "git_diff", "git_log", "changed_files", "revert_changes",
            "worktree_create", "worktree_list", "git_commit", "pr_status",
            "mcp_mcp-filesystem", "mcp_mcp-git",
        ],
        "research-agent": [
            "web_search", "fetch_url", "document_extract", "image_analyze", "mlx_vision_describe",
            "workspace_semantic_search", "file_read", "file_list", "grep", "glob",
            "find_symbol", "document_symbols", "git_log",
            "get_current_date", "calculator",
            "mcp_mcp-fetch",
        ],
        "reviewer-agent": readCode + [
            "git_diff", "git_status", "git_log", "changed_files", "pr_status",
            "build_project", "run_tests", "todo_write", "mcp_mcp-git",
        ],
        "architect-agent": [
            "file_read", "file_list", "glob", "grep", "workspace_semantic_search",
            "find_symbol", "document_symbols", "call_hierarchy", "find_references", "git_log",
            "web_search", "fetch_url",
            "agent_spawn", "todo_write", "ask_user",
            "mcp_mcp-filesystem",
        ],

        // Specialists carried over from Radiant.
        "explainer-agent": readCode + [
            "workspace_semantic_search", "git_log", "web_search", "fetch_url",
        ],
        "security-agent": readCode + [
            "workspace_semantic_search", "git_diff", "git_status", "git_log", "changed_files",
            "web_search", "fetch_url", "todo_write",
        ],
        "sales-agent": [
            "web_search", "fetch_url", "document_extract", "file_read", "file_list", "file_write",
            "edit_file", "get_current_date", "calculator",
            "gmail_search", "mcp_mcp-fetch",
        ],
        "design-agent": [
            "file_read", "file_list", "grep", "glob", "file_write", "edit_file",
            "web_search", "fetch_url", "image_analyze", "mlx_vision_describe",
            "screenshot_window", "accessibility_tree",
            "run_app", "quit_app", "preview_start", "preview_check", "preview_logs", "preview_stop",
        ],
        "education-agent": [
            "file_read", "file_list", "grep", "glob", "document_extract", "web_search", "fetch_url",
            "calculator", "get_current_date",
        ],
        "finance-agent": [
            "calculator", "web_search", "fetch_url", "document_extract", "file_read", "file_list",
            "file_write", "edit_file", "get_current_date",
        ],
        "devops-agent": readCode + [
            "file_write", "edit_file", "multi_edit", "terminal_command", "send_input", "build_project", "run_tests",
            "git_status", "git_diff", "git_log", "changed_files", "web_search", "fetch_url",
            "todo_write", "mcp_mcp-git",
        ],
        "data-agent": [
            "file_read", "file_list", "grep", "glob", "file_write", "edit_file", "terminal_command",
            "document_extract", "calculator", "web_search", "fetch_url", "get_current_date",
        ],
        "docs-agent": readCode + [
            "workspace_semantic_search", "document_extract", "file_write", "edit_file", "multi_edit",
            "git_log", "git_diff", "web_search", "fetch_url",
        ],

        // Knowledge-worker (Cowork) agents.
        "admin-finance-agent": [
            "file_read", "file_list", "file_write", "edit_file", "glob", "grep", "document_extract",
            "calculator", "get_current_date", "gmail_list", "gmail_search",
            "todo_write", "web_search", "fetch_url",
        ],
        "sales-marketing-agent": [
            "web_search", "fetch_url", "document_extract", "file_read", "file_list", "file_write",
            "edit_file", "glob", "grep", "calculator", "get_current_date", "gmail_search",
            "todo_write", "mcp_mcp-fetch",
        ],
        "operations-pm-agent": [
            "file_read", "file_list", "file_write", "edit_file", "glob", "grep", "document_extract",
            "calculator", "get_current_date", "google_calendar_list", "google_calendar_upcoming",
            "todo_write",
        ],
        "comms-organizer-agent": [
            "file_read", "file_list", "file_write", "file_copy", "file_move", "edit_file", "glob", "grep",
            "document_extract", "image_analyze", "mlx_vision_describe",
            "gmail_list", "gmail_search", "google_calendar_list", "google_calendar_upcoming",
            "get_current_date", "todo_write",
        ],
    ]

    // MARK: - Hindsight memory

    /// The Hindsight MCP server's id in the shipped settings.
    public static let hindsightServerId = "mcp-hindsight"

    /// Hindsight tool entries are written by their namespaced name (`mcp__<server>__<tool>`, as
    /// `MCPNamespacedTool` builds it — that type lives in Engine, which Storage cannot import), not
    /// as `mcp_<server>`: the whole-server form would admit all 36 of Hindsight's tools, including
    /// `clear_memories` and `delete_bank`. An agent only ever needs the three below.
    public static func hindsightTool(_ name: String) -> String {
        "mcp__\(hindsightServerId)__\(name)"
    }

    /// Every agent: `recall` to read what is already known, `retain` to store a lasting fact.
    /// (`sync_retain` is the blocking twin of `retain`; nothing here waits on it.)
    public static let hindsightCore = ["recall", "retain"].map(hindsightTool)

    /// `reflect` reasons across many memories to answer a question. Only the agents that plan,
    /// research or audit across sessions use it; for the rest `recall` is enough.
    public static let hindsightWithReflect = hindsightCore + [hindsightTool("reflect")]

    static let reflectingAgentIds: Set<String> = ["lead-assistant", "research-agent", "architect-agent", "security-agent"]

    /// Tools to match on and strip when memory moves to Hindsight: the native pair is switched off
    /// and the Memory Graph server would be a second, unsynced store.
    static let retiredMemoryTools: Set<String> = ["memory_store", "memory_recall", "mcp_mcp-memory"]

    /// `allowedToolIds` per agent id: the role tools above plus its Hindsight tools.
    public static let toolsByAgentId: [String: [String]] = baseToolsByAgentId.reduce(into: [:]) { result, entry in
        result[entry.key] = entry.value + (reflectingAgentIds.contains(entry.key) ? hindsightWithReflect : hindsightCore)
    }

    // MARK: - New agents

    /// What a brand-new agent starts with, from the Agents tab's "New Agent" or a persona template.
    /// A read-only, least-privilege set — no shell, no writes, no delegation — that the user then
    /// widens in the editor. A new agent with an empty allowlist would otherwise get every tool.
    public static let newAgentTools: [String] = [
        "file_read", "file_list", "grep", "glob", "workspace_semantic_search",
        "web_search", "fetch_url", "get_current_date", "todo_write",
    ] + hindsightCore

    public static let newAgentSkills: [String] = ["source-evaluation-skill"]

    /// Gives `agent` the new-agent baseline unless it already carries a list of its own.
    public static func applyNewAgentBaseline(to agent: inout Agent) {
        if agent.allowedToolIds.isEmpty { agent.allowedToolIds = newAgentTools }
        if (agent.allowedSkillIds ?? []).isEmpty { agent.allowedSkillIds = newAgentSkills }
    }

    /// Brings an install up to the Hindsight tool set, once: built-ins get their role's tools (the
    /// native memory tools and the Memory Graph server dropped), and any other agent with an
    /// allowlist of its own just gains `recall` and `retain`. Agents with an empty allowlist
    /// already get everything. Returns true when anything changed.
    @discardableResult
    public static func migrateToHindsight(_ agents: inout [Agent]) -> Bool {
        var changed = false
        for i in agents.indices where !agents[i].allowedToolIds.isEmpty {
            var tools = agents[i].allowedToolIds.filter { !retiredMemoryTools.contains($0) }
            let wanted: [String]
            if agents[i].isBuiltIn, let profile = toolsByAgentId[agents[i].id] {
                wanted = profile.filter { $0.hasPrefix("mcp__\(hindsightServerId)__") }
            } else {
                wanted = hindsightCore
            }
            for tool in wanted where !tools.contains(tool) { tools.append(tool) }
            if tools != agents[i].allowedToolIds {
                agents[i].allowedToolIds = tools
                agents[i].updatedAt = Date()
                changed = true
            }
        }
        return changed
    }

    /// Which skills each agent is shown (`Agent.allowedSkillIds`). Skills used to go to every agent.
    /// `project:<folder>` names a skill in the repository's `.swiftopenwork/skills/`.
    public static let skillsByAgentId: [String: [String]] = baseSkillsByAgentId.reduce(into: [:]) { result, entry in
        result[entry.key] = entry.value + (globalSkillsByAgentId[entry.key] ?? [])
    }

    static let baseSkillsByAgentId: [String: [String]] = [
        "lead-assistant": ["task-delegation-skill", "git-expert-skill", "project:build-and-test"],
        "coder-agent": ["swift-conventions-skill", "git-expert-skill", "project:build-and-test"],
        "research-agent": ["source-evaluation-skill"],
        "reviewer-agent": ["code-reviewer-skill", "swift-conventions-skill", "project:build-and-test"],
        "architect-agent": ["architecture-decision-skill", "swift-conventions-skill", "source-evaluation-skill"],
        "explainer-agent": ["teaching-skill", "swift-conventions-skill"],
        "security-agent": ["security-auditor-skill", "code-reviewer-skill", "source-evaluation-skill"],
        "sales-agent": ["sales-outreach-skill", "source-evaluation-skill"],
        "design-agent": [
            "project:design-ui-designer", "project:design-ux-architect", "project:design-ux-researcher",
            "project:design-brand-guardian", "project:design-ui-finish-gate-reviewer",
            "project:design-persona-walkthrough", "project:design-inclusive-visuals-specialist",
            "project:design-visual-storyteller", "project:design-whimsy-injector",
            "project:design-image-prompt-engineer",
        ],
        "education-agent": ["teaching-skill", "source-evaluation-skill"],
        "finance-agent": ["financial-analysis-skill", "source-evaluation-skill"],
        "devops-agent": ["devops-runbook-skill", "security-auditor-skill", "git-expert-skill", "project:build-and-test"],
        "data-agent": ["data-analysis-skill", "source-evaluation-skill"],
        "docs-agent": ["technical-writing-skill", "source-evaluation-skill"],
        "admin-finance-agent": ["invoicing-admin-skill", "financial-analysis-skill"],
        "sales-marketing-agent": ["sales-outreach-skill", "source-evaluation-skill", "comms-briefing-skill"],
        "operations-pm-agent": ["project-planning-skill", "task-delegation-skill"],
        "comms-organizer-agent": ["comms-briefing-skill"],
    ]

    /// Skills installed for the user in `~/.agents/skills` (BAMA, "Build Any Mac App", and the
    /// engineering-workflow skills beside it), per agent. Skills for other tools (Orca, ai-memory,
    /// the Understand graph, skill authoring) are left off every agent: they need tools this app lacks.
    /// `global:<folder>` names a skill by its folder, as `ProjectSkills.loadGlobal` ids it.
    ///
    /// Only the agents whose work the skill is for get it: an agent that never builds, designs or
    /// plans a Mac app would only carry the descriptions in its prompt. Agents not listed here
    /// (sales, finance, education, data, the Cowork agents) get none.
    public static let globalSkillsByAgentId: [String: [String]] = [
        // Orchestrates; `bama` is the router that picks the next skill, the rest are for workers.
        "lead-assistant": [
            "global:bama", "global:planning-and-task-breakdown", "global:spec-driven-development",
            "global:interview-me",
        ],
        "coder-agent": [
            "global:swift-swiftui", "global:build-and-verify", "global:test-mac-app", "global:performance",
            "global:os-integrations", "global:layout-grid", "global:new-mac-app",
            "global:debugging-and-error-recovery", "global:incremental-implementation",
            "global:test-driven-development", "global:swift-testing-pro", "global:swiftui-pro",
            "global:code-simplification",
        ],
        "research-agent": ["global:research", "global:source-driven-development"],
        "reviewer-agent": [
            "global:swift-swiftui", "global:test-mac-app", "global:improve-architecture",
            "global:mac-design", "global:layout-grid", "global:performance",
            "global:code-review-and-quality", "global:swiftui-pro", "global:swift-testing-pro",
            "global:code-simplification", "global:doubt-driven-development",
        ],
        "architect-agent": [
            "global:improve-architecture", "global:app-brief", "global:user-stories",
            "global:os-integrations", "global:swift-swiftui", "global:api-and-interface-design",
            "global:documentation-and-adrs", "global:spec-driven-development",
            "global:deprecation-and-migration", "global:planning-and-task-breakdown",
        ],
        "explainer-agent": ["global:swift-swiftui"],
        "security-agent": ["global:os-integrations", "global:security-and-hardening"],
        "design-agent": [
            "global:mac-design", "global:design-system", "global:design-kit", "global:design-from-app",
            "global:layout-grid", "global:app-icon", "global:ux-design", "global:swiftui-design-principles",
        ],
        "devops-agent": [
            "global:build-and-verify", "global:test-mac-app", "global:ci-cd-and-automation",
            "global:shipping-and-launch", "global:observability-and-instrumentation",
            "global:git-workflow-and-versioning",
        ],
        "docs-agent": [
            "global:app-brief", "global:user-stories", "global:documentation-and-adrs",
            "global:source-driven-development",
        ],
        "operations-pm-agent": [
            "global:user-stories", "global:app-brief", "global:planning-and-task-breakdown",
        ],
    ]

    /// Adds each built-in agent's `globalSkillsByAgentId` entries to an allowlist it already has.
    /// An agent with an empty allowlist already sees everything, so it is left alone. Returns true
    /// when anything changed.
    @discardableResult
    public static func addGlobalSkills(to agents: inout [Agent]) -> Bool {
        var changed = false
        for i in agents.indices where agents[i].isBuiltIn {
            guard let wanted = globalSkillsByAgentId[agents[i].id],
                  var skills = agents[i].allowedSkillIds, !skills.isEmpty else { continue }
            let missing = wanted.filter { !skills.contains($0) }
            guard !missing.isEmpty else { continue }
            skills.append(contentsOf: missing)
            agents[i].allowedSkillIds = skills
            agents[i].updatedAt = Date()
            changed = true
        }
        return changed
    }

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
            if (agents[i].allowedSkillIds ?? []).isEmpty, let skills = skillsByAgentId[id] {
                agents[i].allowedSkillIds = skills
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
            Skill(
                id: "teaching-skill",
                name: "Teaching & Explaining",
                description: "Teach top-down in plain language, with small examples and a check for understanding.",
                category: "Education",
                content: """
                # Teaching & Explaining
                1. Start from the big picture, then the parts; one idea per step.
                2. Use plain words, a small concrete example, and an analogy where it helps.
                3. Ask a quick question to check understanding; adapt to the answer.
                """,
                source: .builtIn
            ),
            Skill(
                id: "sales-outreach-skill",
                name: "Sales Outreach & Positioning",
                description: "Short, benefit-led outreach; qualify before pitching; handle objections honestly.",
                category: "Sales",
                content: """
                # Sales Outreach & Positioning
                1. Lead with the reader's problem, then one concrete benefit; keep it under 120 words.
                2. Qualify: need, budget, authority, timing, before proposing.
                3. Answer objections with evidence; never invent numbers or customers.
                """,
                source: .builtIn
            ),
            Skill(
                id: "financial-analysis-skill",
                name: "Financial Analysis",
                description: "State assumptions, show the math, sanity-check, end with a bottom line.",
                category: "Finance",
                content: """
                # Financial Analysis
                1. List assumptions and units first.
                2. Show each calculation; cross-check totals and orders of magnitude.
                3. Give ranges and risks, then a one-line conclusion. Not personalised investment advice.
                """,
                source: .builtIn
            ),
            Skill(
                id: "devops-runbook-skill",
                name: "DevOps Runbooks & Reliability",
                description: "Reproducible, observable changes with a rollback and least privilege.",
                category: "DevOps",
                content: """
                # DevOps Runbooks & Reliability
                1. Prefer scripted, idempotent steps over manual ones; give exact commands.
                2. For every change state the failure modes and how to roll back.
                3. Use least privilege; never put secrets in files or logs.
                """,
                source: .builtIn
            ),
            Skill(
                id: "data-analysis-skill",
                name: "Data Analysis",
                description: "Check the data before concluding; report findings with caveats.",
                category: "Data",
                content: """
                # Data Analysis
                1. Inspect shape, types, nulls and duplicates before analysing.
                2. Keep queries and code reproducible; verify joins and filters with counts.
                3. Report the finding, its confidence, and what could change it. Label every chart axis.
                """,
                source: .builtIn
            ),
            Skill(
                id: "technical-writing-skill",
                name: "Technical Writing",
                description: "Accurate docs written from the code, for the reader's level.",
                category: "Docs",
                content: """
                # Technical Writing
                1. Read the code first; document what it does, not what it was meant to do.
                2. Lead with purpose and a runnable example; then reference detail.
                3. Short headings, consistent terms, no stale claims.
                """,
                source: .builtIn
            ),
            Skill(
                id: "invoicing-admin-skill",
                name: "Invoicing & Admin",
                description: "Quotes to invoices, polite payment reminders, consistent records.",
                category: "Admin",
                content: """
                # Invoicing & Admin
                1. Invoices carry number, dates, line items, totals, tax and payment terms; check the arithmetic.
                2. Reminders escalate politely: R1 friendly, R2 firm, R3 final notice with consequences.
                3. Never invent amounts or dates; ask when a figure is missing.
                """,
                source: .builtIn
            ),
            Skill(
                id: "project-planning-skill",
                name: "Project & Operations Planning",
                description: "Milestones, dependencies, owners and checklists that can be tracked.",
                category: "Operations",
                content: """
                # Project & Operations Planning
                1. Break work into milestones with owner, date and dependency.
                2. Flag the critical path and the biggest risk for each milestone.
                3. Turn recurring work into a short SOP checklist.
                """,
                source: .builtIn
            ),
            Skill(
                id: "comms-briefing-skill",
                name: "Communications & File Organisation",
                description: "Sort files, extract receipts, summarise meetings, draft clear messages.",
                category: "Communications",
                content: """
                # Communications & File Organisation
                1. Sort by type and date; move or copy, never delete; report what moved.
                2. Extract receipt fields (date, vendor, total, tax) into rows; flag unreadable ones.
                3. Meeting summaries: decisions, owners, deadlines. Drafts are never sent without the user's say-so.
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
