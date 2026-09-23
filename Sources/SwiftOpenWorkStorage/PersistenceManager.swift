import Foundation
import SwiftOpenWorkCore

public final class PersistenceManager: Sendable {
    public static let shared = PersistenceManager()

    private let storage = StorageService.shared
    private let sessionWriter = SessionWriter()

    private init() {
        // Core's logger cannot see settings; point its verbose switch at them.
        AppLog.setVerboseSource { PersistenceManager.shared.loadSettings().verboseLogging }
    }

    // MARK: - Workspaces
    public var defaultWorkspaces: [Workspace] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseWs = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath)
        return [
            Workspace(
                id: "default-workspace",
                name: "Main Workspace",
                icon: "briefcase.fill",
                color: "#6366F1",
                folderPath: (baseWs as NSString).appendingPathComponent("Main"),
                category: .general,
                assignedAgentId: "lead-assistant",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "ai-research",
                name: "AI & Agent Research",
                icon: "brain.head.profile",
                color: "#EC4899",
                folderPath: (baseWs as NSString).appendingPathComponent("AI-Research"),
                category: .research,
                assignedAgentId: "research-agent",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "personal-workspace",
                name: "Personal Projects",
                icon: "folder.fill",
                color: "#10B981",
                folderPath: (baseWs as NSString).appendingPathComponent("Personal-Projects"),
                category: .project,
                assignedAgentId: nil,
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "coder-workspace",
                name: "Software Engineer Workspace",
                icon: "chevron.left.forwardslash.chevron.right",
                color: "#3B82F6",
                folderPath: (baseWs as NSString).appendingPathComponent("Software-Engineer"),
                category: .agent,
                assignedAgentId: "coder-agent",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "reviewer-workspace",
                name: "Code Review & QA Workspace",
                icon: "checkmark.shield.fill",
                color: "#F59E0B",
                folderPath: (baseWs as NSString).appendingPathComponent("Code-Review"),
                category: .agent,
                assignedAgentId: "reviewer-agent",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            ),
            Workspace(
                id: "data-workspace",
                name: "Data & Analytics Workspace",
                icon: "chart.bar.xaxis",
                color: "#06B6D4",
                folderPath: (baseWs as NSString).appendingPathComponent("Data-Analytics"),
                category: .agent,
                assignedAgentId: "data-analyst",
                isPipelineStagingEnabled: true,
                inputFolderPath: "input",
                outputFolderPath: "output"
            )
        ]
    }

    public func loadWorkspaces() -> [Workspace] {
        var items: [Workspace] = []
        if let loaded = storage.load([Workspace].self, from: "workspaces.json"), !loaded.isEmpty {
            items = loaded
        } else {
            items = defaultWorkspaces
            saveWorkspaces(items)
        }

        // Sanitize any obsolete/invalid SF symbols in stored workspace categories/icons
        var modified = false
        for i in 0..<items.count {
            if items[i].icon == "person.crop.circle.badge.sparkables" || items[i].icon == "person.crop.circle.badge.sparkles" {
                items[i].icon = "person.crop.circle.badge.checkmark"
                modified = true
            }
        }

        // Merge any new default workspace presets that don't exist yet
        for def in defaultWorkspaces {
            if !items.contains(where: { $0.id == def.id }) {
                items.append(def)
                modified = true
            }
        }
        if modified {
            saveWorkspaces(items)
        }
        return items
    }

    public func saveWorkspaces(_ workspaces: [Workspace]) {
        storage.save(workspaces, to: "workspaces.json")
    }

    // MARK: - Settings
    /// Read the stored settings. Writes only when something actually needs writing.
    ///
    /// This is called per turn, per tool call, and six times over in `MCPProtocol` — 26 sites in
    /// all. Every branch below used to end in a write, including the steady-state one, so a
    /// function whose entire job is to read rewrote `mcp_servers.json` on every call: a
    /// synchronous atomic write, under a lock, from the main thread among others. Proving it took
    /// nothing more than watching the file's mtime move during a test that only read settings.
    ///
    /// The repairs and the migration are still applied in memory on every load, so callers always
    /// see corrected values; they just do not hit the disk once they have converged.
    public func loadSettings() -> AppSettings {
        var settings: AppSettings
        var needsSave = false
        if let loaded = storage.load(AppSettings.self, from: "settings.json") {
            settings = loaded
        } else {
            settings = AppSettings.default
            needsSave = true
        }

        if Self.applyMigrations(to: &settings) {
            needsSave = true
        }

        // Synchronize MCP servers (repair known-bad launch args before either side wins).
        let backupMcp = loadMCPServers()
        if settings.mcpServers.isEmpty {
            settings.mcpServers = backupMcp
            needsSave = true
        } else {
            let repaired = repairMCPServerArgs(settings.mcpServers)
            if repaired != settings.mcpServers {
                settings.mcpServers = repaired
                needsSave = true
            } else if backupMcp != settings.mcpServers {
                // The backup store has drifted from settings.json. `saveSettings` mirrors both,
                // so this converges after one write instead of repeating forever.
                needsSave = true
            }
        }

        if needsSave {
            saveSettings(settings)
        }

        return settings
    }

    /// Fix up a stored settings file whose schema predates the current one.
    ///
    /// Returns whether anything changed. A migration must be keyed on the stored version, not on
    /// the values themselves: re-deriving "this looks unset" on every load would mean the user
    /// could never turn the setting back off.
    public static func applyMigrations(to settings: inout AppSettings) -> Bool {
        guard settings.settingsSchemaVersion < AppSettings.currentSchemaVersion else { return false }

        if settings.settingsSchemaVersion < 2 {
            // The voice toggles shipped defaulting to false while nothing read them, and the mic
            // button in the composer and the speak button on every assistant message were drawn
            // regardless. Now that those buttons honour the settings, a stored `false` written by
            // a build where the switch did nothing would silently remove a working feature. It
            // was never a preference, so it does not survive as one.
            settings.voiceInputEnabled = true
            settings.voiceSynthesisEnabled = true
        }

        settings.settingsSchemaVersion = AppSettings.currentSchemaVersion
        return true
    }

    public func saveSettings(_ settings: AppSettings) {
        storage.save(settings, to: "settings.json")
        saveMCPServers(settings.mcpServers)
        // So flipping "Verbose Logging" takes effect without a relaunch.
        AppLog.invalidate()
    }

    // MARK: - MCP Servers Backup Store
    public func loadMCPServers() -> [MCPServerConfig] {
        if let servers = storage.load([MCPServerConfig].self, from: "mcp_servers.json"), !servers.isEmpty {
            let repaired = repairMCPServerArgs(servers)
            if repaired != servers {
                saveMCPServers(repaired)
            }
            return repaired
        }
        let defaults = AppSettings.defaultMCPServers
        saveMCPServers(defaults)
        return defaults
    }

    /// Fix known-bad MCP launch args that cause child processes to exit immediately (and used to crash the app).
    private func repairMCPServerArgs(_ servers: [MCPServerConfig]) -> [MCPServerConfig] {
        servers.map { server in
            var s = server
            let isCodegraph = s.command.lowercased().contains("codegraph")
                || s.name.lowercased().contains("codegraph")
            guard isCodegraph else { return s }
            let sanitized = MCPServerConfig.sanitizedStdioArgs(command: s.command, name: s.name, args: s.args)
            if sanitized != s.args {
                s.args = sanitized
            }
            return s
        }
    }

    public func saveMCPServers(_ servers: [MCPServerConfig]) {
        storage.save(servers, to: "mcp_servers.json")
    }

    // MARK: - Providers
    public var defaultProviders: [ModelProvider] {
        [
            ModelProvider(
                id: "builtin-mlx-local",
                name: "Built-in (Apple Silicon MLX)",
                type: .local,
                kind: .omlx,
                baseUrl: "http://127.0.0.1:8000/v1",
                apiKey: "",
                isEnabled: true,
                isDefault: true,
                models: [
                    // Smallest model first and marked as default: a fresh install shouldn't
                    // silently kick off a 30-70GB download the first time someone sends a chat
                    // message. Larger models remain selectable from the model picker.
                    ModelInfo(id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit", name: "DeepSeek R1 Distill 14B (MLX)", providerId: "builtin-mlx-local", contextWindow: 131072, supportsReasoning: true, isDefault: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", name: "Qwen 2.5 Coder 32B (MLX 4-bit)", providerId: "builtin-mlx-local", contextWindow: 131072, supportsTools: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/Qwen3.8-27B-8bit", name: "Qwen3.8 27B (8-bit)", providerId: "builtin-mlx-local", contextWindow: 131072, speedTier: "Balanced"),
                    ModelInfo(id: "mlx-community/Qwen3.8-27B-MLX-8bit", name: "Qwen3.8 27B MLX (Vision 8-bit)", providerId: "builtin-mlx-local", contextWindow: 131072, supportsVision: true, speedTier: "Balanced"),
                    ModelInfo(id: "mlx-community/Qwen3.6-35B-A3B-8bit", name: "Qwen3.6 35B (8-bit)", providerId: "builtin-mlx-local", contextWindow: 131072, speedTier: "Powerful"),
                    ModelInfo(id: "mlx-community/Ornith-1.5-35B-A3B-8bit", name: "Ornith 1.5 35B A3B 8bit", providerId: "builtin-mlx-local", contextWindow: 262144, supportsReasoning: true, supportsTools: true, speedTier: "Powerful"),
                    ModelInfo(id: "mlx-community/Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit", name: "Qwen3 Coder Next REAP 48B (8-bit)", providerId: "builtin-mlx-local", contextWindow: 131072, supportsTools: true, speedTier: "Powerful")
                ]
            ),
            ModelProvider(
                id: "ollama-local",
                name: "Ollama (Local)",
                type: .local,
                kind: .ollama,
                baseUrl: "http://127.0.0.1:11434",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "llama3:latest", name: "Llama 3 (8B)", providerId: "ollama-local", contextWindow: 8192, supportsVision: false, supportsReasoning: false, isDefault: true, speedTier: "Fast"),
                    ModelInfo(id: "llama3.3:latest", name: "Llama 3.3 (70B)", providerId: "ollama-local", contextWindow: 131072, supportsVision: false, supportsReasoning: false, speedTier: "Powerful"),
                    ModelInfo(id: "mistral:latest", name: "Mistral 7B", providerId: "ollama-local", contextWindow: 32768, supportsVision: false, supportsReasoning: false, speedTier: "Fast"),
                    ModelInfo(id: "deepseek-r1:8b", name: "DeepSeek R1 (8B Reasoning)", providerId: "ollama-local", contextWindow: 65536, supportsVision: false, supportsReasoning: true, speedTier: "Balanced"),
                    ModelInfo(id: "qwen2.5-coder:7b", name: "Qwen 2.5 Coder (7B)", providerId: "ollama-local", contextWindow: 32768, supportsVision: false, supportsReasoning: false, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "vmlx-local",
                name: "vMLX (Vision & Multi-Modal)",
                type: .local,
                kind: .vmlx,
                baseUrl: "http://127.0.0.1:8080/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "mlx-community/Qwen2-VL-7B-Instruct-4bit", name: "Qwen2 VL 7B (Vision MLX)", providerId: "vmlx-local", contextWindow: 32768, supportsVision: true, isDefault: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit", name: "Llama 3.2 Vision 11B (MLX)", providerId: "vmlx-local", contextWindow: 128000, supportsVision: true, speedTier: "Fast"),
                    ModelInfo(id: "mlx-community/pixtral-12b-4bit", name: "Pixtral 12B Vision (MLX)", providerId: "vmlx-local", contextWindow: 128000, supportsVision: true, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "lmstudio-local",
                name: "LM Studio (Local)",
                type: .local,
                kind: .lmstudio,
                baseUrl: "http://127.0.0.1:1234/v1",
                apiKey: "",
                isEnabled: false,
                models: [
                    ModelInfo(id: "local-model", name: "Active LM Studio Model", providerId: "lmstudio-local", contextWindow: 32768, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "openai-cloud",
                name: "OpenAI",
                type: .cloud,
                kind: .openai,
                baseUrl: "https://api.openai.com/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "gpt-4o", name: "GPT-4o (Omni)", providerId: "openai-cloud", contextWindow: 128000, supportsVision: true, supportsReasoning: false, isDefault: true, speedTier: "Fast", costPer1kPrompt: 0.005, costPer1kCompletion: 0.015),
                    ModelInfo(id: "gpt-4o-mini", name: "GPT-4o Mini", providerId: "openai-cloud", contextWindow: 128000, supportsVision: true, supportsReasoning: false, speedTier: "Fast", costPer1kPrompt: 0.00015, costPer1kCompletion: 0.0006),
                    ModelInfo(id: "o1", name: "o1 Reasoning", providerId: "openai-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: true, speedTier: "Powerful", costPer1kPrompt: 0.015, costPer1kCompletion: 0.06),
                    ModelInfo(id: "o3-mini", name: "o3-mini", providerId: "openai-cloud", contextWindow: 200000, supportsVision: false, supportsReasoning: true, speedTier: "Fast", costPer1kPrompt: 0.0011, costPer1kCompletion: 0.0044)
                ]
            ),
            ModelProvider(
                id: "anthropic-cloud",
                name: "Anthropic Claude",
                type: .cloud,
                kind: .anthropic,
                baseUrl: "https://api.anthropic.com/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "claude-3-7-sonnet-20250219", name: "Claude 3.7 Sonnet (Hybrid Reasoning)", providerId: "anthropic-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: true, isDefault: true, speedTier: "Powerful", costPer1kPrompt: 0.003, costPer1kCompletion: 0.015),
                    ModelInfo(id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", providerId: "anthropic-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: false, speedTier: "Powerful", costPer1kPrompt: 0.003, costPer1kCompletion: 0.015),
                    ModelInfo(id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", providerId: "anthropic-cloud", contextWindow: 200000, supportsVision: true, supportsReasoning: false, speedTier: "Fast", costPer1kPrompt: 0.0008, costPer1kCompletion: 0.004)
                ]
            ),
            ModelProvider(
                id: "groq-cloud",
                name: "Groq",
                type: .cloud,
                kind: .groq,
                baseUrl: "https://api.groq.com/openai/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B Versatile", providerId: "groq-cloud", contextWindow: 128000, speedTier: "Fast"),
                    ModelInfo(id: "deepseek-r1-distill-llama-70b", name: "DeepSeek R1 Distill 70B", providerId: "groq-cloud", contextWindow: 128000, supportsReasoning: true, speedTier: "Fast")
                ]
            ),
            ModelProvider(
                id: "openrouter-cloud",
                name: "OpenRouter",
                type: .cloud,
                kind: .openrouter,
                baseUrl: "https://openrouter.ai/api/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "anthropic/claude-3.7-sonnet", name: "Claude 3.7 Sonnet (via OpenRouter)", providerId: "openrouter-cloud", contextWindow: 200000, supportsReasoning: true, speedTier: "Powerful"),
                    ModelInfo(id: "meta-llama/llama-3.3-70b-instruct", name: "Llama 3.3 70B Instruct", providerId: "openrouter-cloud", contextWindow: 131072, speedTier: "Fast"),
                    ModelInfo(id: "deepseek/deepseek-r1", name: "DeepSeek R1", providerId: "openrouter-cloud", contextWindow: 65536, supportsReasoning: true, speedTier: "Powerful")
                ]
            ),
            ModelProvider(
                id: "deepseek-cloud",
                name: "DeepSeek",
                type: .cloud,
                kind: .deepseek,
                baseUrl: "https://api.deepseek.com/v1",
                apiKey: "",
                isEnabled: true,
                models: [
                    ModelInfo(id: "deepseek-chat", name: "DeepSeek-V3", providerId: "deepseek-cloud", contextWindow: 64000, speedTier: "Fast"),
                    ModelInfo(id: "deepseek-reasoner", name: "DeepSeek-R1 (Reasoning)", providerId: "deepseek-cloud", contextWindow: 64000, supportsReasoning: true, speedTier: "Powerful")
                ]
            ),
            ModelProvider(
                id: "custom-openai",
                name: "Custom OpenAI-Compatible",
                type: .cloud,
                kind: .custom,
                baseUrl: "https://api.example.com/v1",
                apiKey: "",
                isEnabled: false,
                models: [
                    ModelInfo(id: "custom-model", name: "Custom Endpoint Model", providerId: "custom-openai", contextWindow: 32768, speedTier: "Balanced")
                ]
            )
        ]
    }

    public func loadProviders() -> [ModelProvider] {
        var loaded: [ModelProvider] = []
        if let items = storage.load([ModelProvider].self, from: "providers.json"), !items.isEmpty {
            loaded = items
        } else {
            loaded = defaultProviders
            saveProviders(loaded)
        }

        // Normalize naming to match Osaurus / GrizzyClaw built-in Apple Silicon engine
        var modified = false
        for i in 0..<loaded.count {
            if loaded[i].kind == .omlx && (loaded[i].name.contains("oMLX") || loaded[i].name.contains("omlx")) {
                loaded[i].name = "Apple Silicon (Built-in)"
                modified = true
            }
        }
        if modified {
            saveProviders(loaded)
        }

        // No Keychain reads here. This runs inside `AppState.loadAll()` on the main thread before
        // the window exists, and a read there can block behind an authorisation prompt — launch
        // hung with no window. Keys are filled in on first use by `ProviderCredentials`.
        return loaded
    }

    public func saveProviders(_ providers: [ModelProvider]) {
        // Move API keys into the Keychain, and actually remove them from the JSON.
        //
        // This said "sanitize for JSON backup" above `let sanitized = providers`, which copies
        // the array and sanitises nothing. Keys were written to the Keychain *and* left in
        // providers.json in plaintext, in a world-readable file — while the README advertised
        // "cloud keys in Keychain". Both halves were true; the second one was the whole risk.
        //
        // The key is cleared only once the Keychain has accepted it, so a Keychain failure
        // degrades to the old behaviour rather than destroying the user's credential.
        var sanitized = providers
        for i in sanitized.indices {
            let key = sanitized[i].apiKey
            guard !key.isEmpty else { continue }
            if KeychainManager.shared.saveSecret(key, forKey: "provider_key_\(sanitized[i].id)") {
                sanitized[i].apiKey = ""
                ProviderCredentials.remember(key, for: sanitized[i].id)
            }
        }
        storage.save(sanitized, to: "providers.json")
    }

    // MARK: - Agents
    /// The allowlist every seeded agent shipped with, in the two shapes the seeds used.
    ///
    /// Matching exactly, rather than by subset, so an allowlist a user narrowed *to* these tools
    /// on purpose is only cleared if it is identical to what was seeded — and a user who has
    /// added or removed anything keeps their choice.
    public static func isLegacySeededAllowlist(_ ids: [String]) -> Bool {
        let base: Set<String> = [
            "file_read", "file_write", "terminal_command", "web_search",
            "calculator", "agent_spawn", "agent_message"
        ]
        let withMemory = base.union(["memory_store", "memory_recall"])
        let stored = Set(ids)
        return stored == base || stored == withMemory
    }

    /// The seed's old self-description with the new name, or nil when there is nothing to change.
    public static func renamedSeedAgentText(_ text: String) -> String? {
        // "OpenWork-Swift" was the name for a few hours before SwiftOpenWork, and test runs in
        // that window already rewrote this machine's agents.json to it. The lookbehind matters:
        // the new name itself contains "OpenWork Lead Agent", and without it every launch would
        // prepend another "Swift".
        let range = NSRange(text.startIndex..., in: text)
        guard seedAgentNamePattern.firstMatch(in: text, range: range) != nil else { return nil }
        return seedAgentNamePattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "SwiftOpenWork Lead Agent"
        )
    }

    private static let seedAgentNamePattern = try! NSRegularExpression(
        pattern: #"(?<!Swift)OpenWork(?:-Swift)? Lead Agent"#
    )

    public func loadAgents() -> [Agent] {
        var items: [Agent] = []
        if let loaded = storage.load([Agent].self, from: "agents.json"), !loaded.isEmpty {
            items = loaded
        } else {
            items = defaultAgents
            saveAgents(items)
            return items
        }

        var modified = false

        // Retire the legacy per-agent tool allowlist.
        //
        // `allowedToolIds` is shown in the Agents editor ("7 tools"), is editable there, and is
        // stored on every agent — and until sub-agents became real, **nothing in any execution
        // path read it**. The seeded value is a list from before most of the catalog existed: no
        // grep, no edit_file, no build_project, no run_tests, none of the perception tools. So
        // the first code to honour it would have handed every sub-agent five useful tools and
        // called that the user's choice.
        //
        // Same reasoning as the voice toggles: a value stored by a control that did nothing is
        // not a preference. Empty means "every tool enabled in the workspace", so clearing the
        // untouched seed restores the intent while leaving a real, deliberate allowlist alone.
        for i in items.indices where Self.isLegacySeededAllowlist(items[i].allowedToolIds) {
            items[i].allowedToolIds = []
            modified = true
        }

        // The app was renamed SwiftOpenWork. The seeded lead agent introduces itself by name,
        // so an install from before the rename would keep answering as "OpenWork". Only the
        // seed's exact wording is changed; a name or prompt the user edited is theirs.
        for i in items.indices {
            if let renamed = Self.renamedSeedAgentText(items[i].name) {
                items[i].name = renamed
                modified = true
            }
            if let renamed = Self.renamedSeedAgentText(items[i].systemPrompt) {
                items[i].systemPrompt = renamed
                modified = true
            }
        }

        // Sanitize any invalid or obsolete SF symbols loaded from user's disk cache
        for i in 0..<items.count {
            if items[i].avatar == "person.crop.circle.badge.sparkables" || items[i].avatar == "person.crop.circle.badge.sparkles" {
                items[i].avatar = "person.crop.circle.badge.checkmark"
                modified = true
            } else if items[i].avatar == "square.3.layers.3d.down.right.fill" {
                items[i].avatar = "square.3.layers.3d.down.right"
                modified = true
            }
        }
        if modified {
            saveAgents(items)
        }
        return items
    }

    public var defaultAgents: [Agent] {
        [
            Agent(
                id: "lead-assistant",
                name: "SwiftOpenWork Lead Agent",
                description: "Primary orchestrator agent capable of answering questions, decomposing complex goals, and spawning specialized sub-agents.",
                avatar: "person.crop.circle.badge.checkmark",
                color: "#8B5CF6",
                role: "Lead General Orchestrator",
                systemPrompt: """
                You are SwiftOpenWork Lead Agent, a robust, highly capable autonomous software engineering and research assistant.
                You can answer queries directly, or orchestrate specialized sub-agents (Coder, Researcher, Critic, Architect) for complex tasks.
                When a task has multiple independent steps, plan methodically, communicate clearly, and leverage tools and sub-agents.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.7,
                maxTokens: 4096,
                topP: 1.0,
                reasoningEffort: .medium,
                parentAgentId: nil,
                subAgentIds: ["coder-agent", "research-agent", "reviewer-agent"],
                canSpawnSubAgents: true,
                maxSubAgentDepth: 3,
                autoDelegate: true,
                canCommunicateWithOthers: true,
                tags: ["General", "Orchestrator", "Lead"],
                isBuiltIn: true,
                isLeadAgent: true
            ),
            Agent(
                id: "coder-agent",
                name: "Software Engineer Agent",
                description: "Specialized in architecture, clean code, debugging, refactoring, and test writing across Swift, Python, TypeScript, Rust, and more.",
                avatar: "chevron.left.forwardslash.chevron.right",
                color: "#3B82F6",
                role: "Senior Software Engineer",
                systemPrompt: """
                You are an expert Senior Software Engineer agent.
                You write clean, idiomatic, robust, and well-tested code.
                Focus on modern paradigms, performance, security, and edge-case handling.
                """,
                providerId: "ollama-local",
                modelId: "qwen2.5-coder:7b",
                temperature: 0.2,
                maxTokens: 8192,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: true,
                maxSubAgentDepth: 2,
                autoDelegate: false,
                canCommunicateWithOthers: true,
                tags: ["Coding", "Architecture", "Engineering"],
                isBuiltIn: true
            ),
            Agent(
                id: "research-agent",
                name: "Deep Research Agent",
                description: "Synthesizes documentation, explores codebases, analyzes repositories, and produces comprehensive factual summaries.",
                avatar: "magnifyingglass.circle.fill",
                color: "#10B981",
                role: "Research & Knowledge Specialist",
                systemPrompt: """
                You are a Deep Research and Technical Analysis agent.
                Your job is to thoroughly investigate questions, find patterns, analyze specifications, and summarize complex information into actionable insights.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.4,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Research", "Analysis", "Documentation"],
                isBuiltIn: true
            ),
            Agent(
                id: "reviewer-agent",
                name: "Code Review & Quality Critic",
                description: "Performs rigorous code review, checks for edge cases, security vulnerabilities, performance regressions, and architectural purity.",
                avatar: "checkmark.shield.fill",
                color: "#F59E0B",
                role: "Quality Assurance & Security Reviewer",
                systemPrompt: """
                You are a meticulous Code Reviewer and Quality Assurance agent.
                Critique designs and implementations constructively, point out defects, race conditions, memory leaks, security holes, and suggest concrete fixes.
                """,
                providerId: "ollama-local",
                modelId: "deepseek-r1:8b",
                temperature: 0.1,
                maxTokens: 4096,
                reasoningEffort: .high,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Review", "Security", "Quality"],
                isBuiltIn: true
            ),
            Agent(
                id: "architect-agent",
                name: "Systems Architect Agent",
                description: "Designs system topology, data flow, API contracts, and high-level structural blueprints.",
                avatar: "square.3.layers.3d.down.right",
                color: "#EC4899",
                role: "Principal Systems Architect",
                systemPrompt: """
                You are a Principal Systems Architect.
                You design scalable software architectures, modular abstractions, data storage strategies, and clean API contracts.
                """,
                providerId: "ollama-local",
                modelId: "llama3.3:latest",
                temperature: 0.5,
                maxTokens: 4096,
                parentAgentId: nil,
                subAgentIds: ["coder-agent"],
                canSpawnSubAgents: true,
                maxSubAgentDepth: 2,
                autoDelegate: true,
                canCommunicateWithOthers: true,
                tags: ["Architecture", "System Design"],
                isBuiltIn: true
            ),
            // Knowledge Worker Agents (Claude Cowork Suite)
            Agent(
                id: "admin-finance-agent",
                name: "Administrative & Invoicing Specialist",
                description: "Automates quotes, professional invoices, payment reminders (R1-R3), and multi-supplier price comparisons.",
                avatar: "doc.text.fill",
                color: "#10B981",
                role: "Finance & Admin Specialist",
                systemPrompt: """
                You are a Knowledge Worker specialized in Business Administration and Invoicing.
                You transform quotes into formal invoices, audit Excel formulas, verify compliance checklists, and write polite, effective payment follow-ups.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.3,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Admin", "Invoices", "Finance", "Cowork"],
                isBuiltIn: true
            ),
            Agent(
                id: "sales-marketing-agent",
                name: "Sales Operations & Marketing Specialist",
                description: "Performs company prospect research, competitor pricing analysis, slide deck drafting, and HTML newsletter creation.",
                avatar: "chart.line.uptrend.xyaxis",
                color: "#F59E0B",
                role: "Sales & Marketing Strategist",
                systemPrompt: """
                You are an expert Sales and Growth Marketing Specialist.
                You research prospect decision-makers, synthesize competitor strengths and reviews, and craft compelling, conversion-focused copy.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.6,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Sales", "Marketing", "Prospecting", "Cowork"],
                isBuiltIn: true
            ),
            Agent(
                id: "operations-pm-agent",
                name: "Operations & Project Planner",
                description: "Builds Gantt milestones, inventory replenishment schedules, standardized SOP quality checklists, and work logs.",
                avatar: "list.bullet.clipboard.fill",
                color: "#6366F1",
                role: "Operations & Project Manager",
                systemPrompt: """
                You are an Operations Manager and Project Planner.
                You turn complex initiatives into clear milestone schedules, track dependencies, build inventory restock alerts, and document quality checklists.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.4,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Operations", "Planning", "Gantt", "Cowork"],
                isBuiltIn: true
            ),
            Agent(
                id: "comms-organizer-agent",
                name: "Communications & Organizer Assistant",
                description: "Sorts input/output files, transcribes receipts via OCR, summarizes meetings, and drafts cross-channel communications.",
                avatar: "tray.full.fill",
                color: "#06B6D4",
                role: "Communications & Workspace Organizer",
                systemPrompt: """
                You are an Executive Communications and File Organization assistant.
                You categorize documents in the input/ folder, extract receipt data into spreadsheets, prepare meeting briefings, and maintain structured cross-session memory.
                """,
                providerId: "ollama-local",
                modelId: "llama3:latest",
                temperature: 0.5,
                maxTokens: 4096,
                parentAgentId: "lead-assistant",
                subAgentIds: [],
                canSpawnSubAgents: false,
                canCommunicateWithOthers: true,
                tags: ["Organization", "OCR", "Email", "Cowork"],
                isBuiltIn: true
            )
        ]
    }

    public func saveAgents(_ agents: [Agent]) {
        storage.save(agents, to: "agents.json")
    }

    // MARK: - Sessions
    public func loadSessions() -> [Session] {
        flushSessionWrites()
        var items: [Session] = []
        if let loaded = storage.load([Session].self, from: "sessions.json"), !loaded.isEmpty {
            items = loaded
        } else {
            let initial = defaultSessions
            saveSessions(initial)
            return initial
        }

        // Sanitize any invalid or obsolete SF symbols loaded in chat message avatars
        var modified = false
        for sIdx in 0..<items.count {
            for mIdx in 0..<items[sIdx].messages.count {
                if items[sIdx].messages[mIdx].agentAvatar == "person.crop.circle.badge.sparkables" || items[sIdx].messages[mIdx].agentAvatar == "person.crop.circle.badge.sparkles" {
                    items[sIdx].messages[mIdx].agentAvatar = "person.crop.circle.badge.checkmark"
                    modified = true
                }

                // Nothing is streaming at load time, by definition. A message saved mid-stream —
                // the app quit, or the turn was abandoned — keeps `isStreaming` true on disk and
                // comes back as a bubble that spins forever with no generation behind it. Seen in
                // a real exported session, where it was also empty.
                if items[sIdx].messages[mIdx].isStreaming {
                    items[sIdx].messages[mIdx].isStreaming = false
                    if items[sIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       items[sIdx].messages[mIdx].toolCalls.isEmpty {
                        items[sIdx].messages[mIdx].content =
                            "*(This turn was interrupted before the model produced anything.)*"
                    }
                    modified = true
                }
            }
        }
        if modified {
            saveSessions(items)
        }
        return items
    }

    public var defaultSessions: [Session] {
        [
            Session(
                id: "welcome-session",
                workspaceId: "default-workspace",
                title: "Welcome to SwiftOpenWork",
                agentId: "lead-assistant",
                providerId: "ollama-local",
                modelId: "llama3:latest",
                isPinned: true,
                messages: [
                    ChatMessage(
                        sessionId: "welcome-session",
                        role: .assistant,
                        content: """
                        # Welcome to SwiftOpenWork 🚀
                        
                        SwiftOpenWork is your native macOS autonomous AI workspace powered by SwiftUI.
                        
                        ### Key Features:
                        - **Local & Cloud Model Providers**: Run models on this Mac with the built-in **Apple Silicon** engine, **Ollama** or **LM Studio**, or connect to **OpenAI**, **Anthropic**, **Groq**, **DeepSeek** and **OpenRouter**.
                        - **Autonomous Multi-Agent Hierarchy**: Lead agents can spawn sub-agents (Coders, Researchers, Reviewers) and communicate in real time.
                        - **Built-in Tool Execution**: Safe file reading/writing, shell commands, web search, and calculation.
                        - **Side Inspector**: Track live sub-agent trees, inter-agent messages, artifacts, and tools.
                        - **100% Standalone & Private**: Full local persistence in Application Support with zero external CLI runtime dependencies.
                        
                        Ask any question below or type `/help` to see available slash commands!
                        """,
                        agentId: "lead-assistant",
                        agentName: "SwiftOpenWork Lead Agent",
                        agentAvatar: "person.crop.circle.badge.checkmark",
                        agentColor: "#8B5CF6",
                        modelId: "llama3:latest"
                    )
                ]
            )
        ]
    }

    /// Chat history is the largest file and the most often written: a reply used to rewrite all
    /// of it, pretty-printed, on the main thread for every streamed chunk. Writes now happen on
    /// one background queue, in order, and only the newest snapshot waiting is written.
    public func saveSessions(_ sessions: [Session]) {
        sessionWriter.save(sessions, with: storage)
    }

    /// Wait until every requested `saveSessions` is on disk: before reading the file back, and
    /// when the app quits.
    public func flushSessionWrites() {
        sessionWriter.flush()
    }

    // MARK: - Tools
    public var defaultTools: [Tool] {
        var tools: [Tool] = [
            Tool(id: "file_read", name: "file_read", displayName: "Read File", description: "Read a text file. Returns content with optional line offset/limit.", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "file_read")),
            Tool(id: "file_write", name: "file_write", displayName: "Write File", description: "Create or overwrite a file with the given content.", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "file_write"), requiresApproval: true),
            Tool(id: "file_list", name: "file_list", displayName: "List Directory", description: "Lists files and subdirectories in a given folder", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "file_list")),
            Tool(id: "file_copy", name: "file_copy", displayName: "Copy File", description: "Copies files or directories from source to destination", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "file_copy"), requiresApproval: true),
            Tool(id: "file_move", name: "file_move", displayName: "Move File", description: "Moves or renames files or directories", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "file_move"), requiresApproval: true),
            Tool(id: "file_delete", name: "file_delete", displayName: "Delete File", description: "Removes a file or directory from disk", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "file_delete"), requiresApproval: true),
            Tool(id: "terminal_command", name: "terminal_command", displayName: "Execute Shell Command", description: "Run a shell command in the workspace (timeout applies).", category: .terminal, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "terminal_command"), requiresApproval: false),
            Tool(id: "web_search", name: "web_search", displayName: "Web Search", description: "Searches the web for documentation, news, APIs, and real-time knowledge", category: .web, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "web_search")),
            Tool(id: "calculator", name: "calculator", displayName: "Math Calculator", description: "Evaluates mathematical expressions and formulas", category: .system, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "calculator")),
            Tool(id: "get_current_date", name: "get_current_date", displayName: "Get Current Date", description: "Returns the current date in YYYY-MM-DD format", category: .system, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "get_current_date")),
            Tool(id: "document_extract", name: "document_extract", displayName: "PDF & Vision OCR Extractor", description: "Extracts text from PDF documents via PDFKit or scanned images/receipts via Apple Vision framework OCR", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "document_extract")),
            Tool(id: "workspace_semantic_search", name: "workspace_semantic_search", displayName: "Workspace Semantic Search (RAG)", description: "Performs local semantic chunk search across all source files in the active workspace", category: .files, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "workspace_semantic_search")),
            Tool(id: "mlx_vision_describe", name: "mlx_vision_describe", displayName: "Describe Image", description: "Describe an image, answering an optional prompt about it. Uses the loaded vision model when one is loaded; otherwise reads text out of it with Apple Vision OCR and says that is what it did.", category: .mediaVision, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "mlx_vision_describe")),
            Tool(id: "image_analyze", name: "image_analyze", displayName: "Read Text In Image", description: "Extract text from a screenshot or image with Apple Vision OCR. Text only — it does not describe what the image depicts.", category: .mediaVision, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "image_analyze")),
            Tool(id: "agent_spawn", name: "agent_spawn", displayName: "Spawn Sub-Agent", description: "Launches a specialized child sub-agent to execute a sub-task autonomously", category: .agents, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "agent_spawn")),
            Tool(id: "agent_message", name: "agent_message", displayName: "Message Agent", description: "Sends an inter-agent message or query to another agent in the network", category: .agents, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "agent_message")),
            Tool(id: "memory_store", name: "memory_store", displayName: "Save to Memory", description: "Saves a persistent fact, preference, or context item to the workspace memory", category: .system, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "memory_store")),
            Tool(id: "memory_recall", name: "memory_recall", displayName: "Recall Memory", description: "Retrieves stored memories by search term or category", category: .system, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "memory_recall")),
            Tool(id: "gmail_list", name: "gmail_list", displayName: "List Gmail Messages", description: "Lists recent Gmail messages matching a search query (requires Google OAuth credentials in Settings → Extensions)", category: .web, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "gmail_list"), isEnabled: false, requiresApproval: false),
            Tool(id: "gmail_search", name: "gmail_search", displayName: "Search Gmail", description: "Searches Gmail with a Gmail query string (e.g. from:boss newer_than:7d)", category: .web, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "gmail_search"), isEnabled: false, requiresApproval: false),
            Tool(id: "google_calendar_list", name: "google_calendar_list", displayName: "List Google Calendar", description: "Lists upcoming events from the primary Google Calendar", category: .web, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "google_calendar_list"), isEnabled: false, requiresApproval: false),
            Tool(id: "google_calendar_upcoming", name: "google_calendar_upcoming", displayName: "Upcoming Google Calendar", description: "Lists Google Calendar events for the next N days", category: .web, parametersJsonSchema: ToolSchemaCatalog.schemaJSON(for: "google_calendar_upcoming"), isEnabled: false, requiresApproval: false)
        ]
        _ = ToolSchemaCatalog.ensureParityTools(in: &tools)
        return tools
    }

    public func loadTools() -> [Tool] {
        var items: [Tool] = []
        if let loaded = storage.load([Tool].self, from: "tools.json"), !loaded.isEmpty {
            items = loaded
        } else {
            items = defaultTools
            _ = ToolSchemaCatalog.ensureParityTools(in: &items)
            _ = ToolSchemaCatalog.applySchemas(to: &items)
            saveTools(items)
            return items
        }

        var modified = ToolSchemaCatalog.ensureParityTools(in: &items)
        if ToolSchemaCatalog.applySchemas(to: &items) { modified = true }

        // Tools that were removed because they did not do what they said. Left in a saved
        // `tools.json` they would keep being offered to the model — `defaultTools` is a seed, not
        // a filter, so nothing else drops a tool an install already has.
        let retired: Set<String> = ["generate_image"]
        if items.contains(where: { retired.contains($0.name) }) {
            items.removeAll { retired.contains($0.name) }
            modified = true
        }

        for def in defaultTools {
            if !items.contains(where: { $0.id == def.id || $0.name == def.name }) {
                var tool = def
                tool.parametersJsonSchema = ToolSchemaCatalog.schemaJSON(for: def.name)
                items.append(tool)
                modified = true
            }
        }

        // Do NOT invent ghost `{server}_call` stubs — Radiant only surfaces real listTools results.
        // Namespaced MCP tools are injected live by AgentRunner via mcpToolDefs().

        if modified {
            saveTools(items)
        }
        return items
    }

    public func saveTools(_ tools: [Tool]) {
        storage.save(tools, to: "tools.json")
    }

    // MARK: - Memory
    public func loadMemories() -> [MemoryItem] {
        if let items = storage.load([MemoryItem].self, from: "memories.json"), !items.isEmpty {
            return items
        }
        let defaults: [MemoryItem] = [
            MemoryItem(
                workspaceId: "default-workspace",
                key: "coding_preference",
                content: "User prefers modern Swift 6 paradigms, clean SwiftUI architectures, strong type safety, and async/await.",
                category: .preference,
                tags: ["Swift", "SwiftUI", "Style"]
            ),
            MemoryItem(
                workspaceId: "default-workspace",
                key: "architecture_rule",
                content: "SwiftOpenWork is an autonomous, standalone desktop app. It does not rely on external node CLI daemons.",
                category: .instruction,
                tags: ["Architecture", "Rules"]
            )
        ]
        saveMemories(defaults)
        return defaults
    }

    public func saveMemories(_ memories: [MemoryItem]) {
        storage.save(memories, to: "memories.json")
    }

    // MARK: - Automations
    public func loadAutomations() -> [Automation] {
        if let items = storage.load([Automation].self, from: "automations.json"), !items.isEmpty {
            return items
        }
        let defaults: [Automation] = [
            Automation(
                workspaceId: "default-workspace",
                name: "Daily Project Status Summary",
                description: "Analyzes workspace files and generates a morning development report.",
                triggerType: .scheduled,
                cronSchedule: "Daily at 9:00 AM",
                targetAgentId: "lead-assistant",
                promptTemplate: "Scan my current workspace files and produce a structured bulleted summary of recent changes and recommended next steps."
            ),
            Automation(
                workspaceId: "default-workspace",
                name: "Automated Code Review on File Save",
                description: "Invokes reviewer agent whenever modified files are saved in the project.",
                triggerType: .fileWatch,
                cronSchedule: "On File Change",
                targetAgentId: "reviewer-agent",
                promptTemplate: "Review newly changed source code for security vulnerabilities, style inconsistencies, and performance regressions."
            )
        ]
        saveAutomations(defaults)
        return defaults
    }

    public func saveAutomations(_ automations: [Automation]) {
        storage.save(automations, to: "automations.json")
    }

    // MARK: - Skills
    public func loadSkills() -> [Skill] {
        if let items = storage.load([Skill].self, from: "skills.json"), !items.isEmpty {
            return items
        }
        let defaults: [Skill] = [
            Skill(
                id: "code-reviewer-skill",
                name: "Code Review & Static Analysis",
                description: "Deep inspection for memory safety, concurrency races, type safety, and architectural modularity.",
                category: "Engineering",
                content: """
                # Code Review Skill
                When reviewing code:
                1. Check for data races and concurrency invariants.
                2. Validate error handling and resource cleanup.
                3. Verify edge cases and bounds checks.
                4. Suggest clean refactorings with minimal cognitive complexity.
                """,
                source: .builtIn
            ),
            Skill(
                id: "security-auditor-skill",
                name: "Security & Vulnerability Audit",
                description: "Audits code for injection, secret leakage, OWASP Top 10, and unsafe deserialization.",
                category: "Security",
                content: """
                # Security Audit Skill
                When auditing systems:
                1. Look for unescaped user inputs and SQL/command injection vulnerabilities.
                2. Ensure secrets and tokens are never hardcoded or leaked into logs.
                3. Validate authentication and authorization checks.
                """,
                source: .builtIn
            ),
            Skill(
                id: "git-expert-skill",
                name: "Git Workflow & PR Generator",
                description: "Generates atomic commit messages, branch strategies, and comprehensive pull request summaries.",
                category: "DevOps",
                content: """
                # Git & PR Skill
                Format concise commit messages following conventional commits:
                - `feat:`, `fix:`, `refactor:`, `test:`, `docs:`
                - Include clear summary and test plan.
                """,
                source: .builtIn
            )
        ]
        saveSkills(defaults)
        return defaults
    }

    public func saveSkills(_ skills: [Skill]) {
        storage.save(skills, to: "skills.json")
    }

    // MARK: - Extensions & Plugins
    public var defaultPlugins: [AppExtensionPlugin] {
        return [
            AppExtensionPlugin(
                id: "plugin-mcp-filesystem",
                name: "Filesystem MCP Engine",
                description: "Model Context Protocol server for deep local file reading, chunk search, and directory operations.",
                version: "1.2.0",
                author: "Model Context Protocol",
                pluginType: .mcpServer,
                source: .builtIn,
                isEnabled: true,
                command: "npx -y @modelcontextprotocol/server-filesystem",
                permissions: ["filesystem:read", "filesystem:write"]
            ),
            AppExtensionPlugin(
                id: "plugin-mcp-fetch",
                name: "Web Fetch & Scraper MCP",
                description: "Fetches and transforms web pages, documentation, and REST endpoints into clean markdown.",
                version: "1.0.4",
                author: "Model Context Protocol",
                pluginType: .mcpServer,
                source: .mcpRegistry,
                isEnabled: true,
                command: "npx -y @modelcontextprotocol/server-fetch",
                permissions: ["network:outbound"]
            ),
            AppExtensionPlugin(
                id: "plugin-voice-whisper",
                name: "macOS Native Voice & Speech",
                description: "System speech synthesis (AVSpeechSynthesizer) and speech-to-text voice recognition.",
                version: "2.1.0",
                author: "Apple Silicon Core",
                pluginType: .voiceAudio,
                source: .builtIn,
                isEnabled: true,
                permissions: ["audio:microphone", "audio:speaker"]
            ),
            AppExtensionPlugin(
                id: "plugin-vision-ocr",
                name: "Vision OCR & Document Extractor",
                description: "PDFKit text parsing and Apple Vision optical character recognition for scans and diagrams.",
                version: "1.5.0",
                author: "Apple Vision Framework",
                pluginType: .mediaVision,
                source: .builtIn,
                isEnabled: true,
                permissions: ["system:vision"]
            ),
            AppExtensionPlugin(
                id: "plugin-script-git",
                name: "Git Automated Diff & Staging Hook",
                description: "Shell script plugin to analyze git dirty trees, commit history, and automated branch workflows.",
                version: "1.0.0",
                author: "SwiftOpenWork Community",
                pluginType: .customScript,
                source: .custom,
                isEnabled: true,
                command: "git status --porcelain",
                permissions: ["shell:exec"]
            ),
            AppExtensionPlugin(
                id: "plugin-gmail",
                name: "Gmail",
                description: "Read and search Gmail via Google APIs. Configure Client ID, API Key, and OAuth Access Token under Extensions → Google Integrations.",
                version: "1.0.0",
                author: "Google / SwiftOpenWork",
                pluginType: .workspaceTool,
                source: .builtIn,
                isEnabled: false,
                permissions: ["network:outbound", "google:gmail.readonly"]
            ),
            AppExtensionPlugin(
                id: "plugin-google-calendar",
                name: "Google Calendar",
                description: "List upcoming Google Calendar events. Configure Client ID, API Key, and OAuth Access Token under Extensions → Google Integrations.",
                version: "1.0.0",
                author: "Google / SwiftOpenWork",
                pluginType: .workspaceTool,
                source: .builtIn,
                isEnabled: false,
                permissions: ["network:outbound", "google:calendar.readonly"]
            )
        ]
    }

    public func loadPlugins() -> [AppExtensionPlugin] {
        var items: [AppExtensionPlugin] = []
        if let loaded = storage.load([AppExtensionPlugin].self, from: "plugins.json"), !loaded.isEmpty {
            items = loaded
        } else {
            let defaults = defaultPlugins
            savePlugins(defaults)
            return defaults
        }

        var modified = false
        for def in defaultPlugins {
            if !items.contains(where: { $0.id == def.id }) {
                items.append(def)
                modified = true
            }
        }
        if modified {
            savePlugins(items)
        }
        return items
    }

    public func savePlugins(_ plugins: [AppExtensionPlugin]) {
        storage.save(plugins, to: "plugins.json")
    }

    // MARK: - Watch Folders & Watch Items
    public var defaultWatchItems: [WatchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultWorkspacePath = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath + "/Main")
        let inputPath = (defaultWorkspacePath as NSString).appendingPathComponent("input")

        return [
            WatchItem(
                id: "watch-morning-brief",
                workspaceId: "default-workspace",
                name: "Workspace Daily Morning Brief",
                description: "Monitors workspace root changes and synthesizes a morning executive brief artifact daily.",
                path: defaultWorkspacePath,
                watchType: .folder,
                fileExtensionsFilter: ["swift", "md", "json", "py", "ts", "txt"],
                targetAgentId: "lead-assistant",
                artifactTemplate: .morningBrief,
                outputDestination: "output",
                isEnabled: true,
                autoGenerateArtifact: true,
                debounceIntervalSeconds: 3.0,
                eventsCount: 4,
                createdArtifactsCount: 2
            ),
            WatchItem(
                id: "watch-pipeline-input",
                workspaceId: "default-workspace",
                name: "Staged Ingestion Pipeline (input/)",
                description: "Monitors the input staging directory. Auto-processes incoming documents and scripts into output summaries.",
                path: inputPath,
                watchType: .folder,
                fileExtensionsFilter: ["*"],
                targetAgentId: "data-analyst-agent",
                artifactTemplate: .fileProcessingPipeline,
                outputDestination: "output",
                isEnabled: true,
                autoGenerateArtifact: true,
                debounceIntervalSeconds: 2.0,
                eventsCount: 8,
                createdArtifactsCount: 4
            ),
            WatchItem(
                id: "watch-code-review-hook",
                workspaceId: "default-workspace",
                name: "Real-Time Code Review Watcher",
                description: "Monitors source code files and generates review artifacts with recommendations on file saves.",
                path: defaultWorkspacePath,
                watchType: .pattern,
                fileExtensionsFilter: ["swift", "ts", "py", "rs", "go"],
                targetAgentId: "reviewer-agent",
                artifactTemplate: .codeReviewDigest,
                outputDestination: "output",
                isEnabled: true,
                autoGenerateArtifact: true,
                debounceIntervalSeconds: 4.0,
                eventsCount: 3,
                createdArtifactsCount: 1
            )
        ]
    }

    public func loadWatchItems() -> [WatchItem] {
        if let items = storage.load([WatchItem].self, from: "watch_items.json"), !items.isEmpty {
            return items
        }
        let defaults = defaultWatchItems
        saveWatchItems(defaults)
        return defaults
    }

    public func saveWatchItems(_ items: [WatchItem]) {
        storage.save(items, to: "watch_items.json")
    }

    // MARK: - Automation Generated Artifacts
    public var defaultArtifacts: [AutomationArtifact] {
        return [
            AutomationArtifact(
                id: "artifact-sample-brief-1",
                workspaceId: "default-workspace",
                watchItemId: "watch-morning-brief",
                agentId: "lead-assistant",
                agentName: "Lead Assistant",
                title: "Executive Morning Brief",
                subtitle: "Automated synthesis of workspace activities & health",
                category: .brief,
                content: """
                # 🌅 Morning Executive Brief
                *Generated automatically by SwiftOpenWork Agent Pipeline*

                ---

                ### 🚀 Key Focus for Today
                - **Autonomous Agent Loop**: Native structured tool schemas (`tools` JSON schema) operating across Anthropic, OpenAI, and Ollama.
                - **Watch Folders Engine**: Real-time folder watching active on workspace directory.
                - **Workspace Health**: All module builds passing cleanly on macOS 14/15 ARM64.

                ---

                ### 📊 Activity & Modifications Summary
                - **Recent Changes**: 12 files updated across UI, State, Engine, and Storage layers.
                - **Memory & Context**: Long-term memory store active with 2 persistent architectural rules.
                - **Extensions Active**: Filesystem MCP, Web Fetch, Vision OCR, Native Voice Engine.

                ---

                ### 🎯 Recommended Next Steps
                1. Review pending tasks in the Automations tab.
                2. Test live artifacts generation in the Live Canvas workbench.
                3. Inspect inter-agent communication logs in the Side Inspector.
                """,
                format: "markdown",
                sourceTrigger: "Watch Folder: Workspace Morning Brief"
            ),
            AutomationArtifact(
                id: "artifact-sample-daily-2",
                workspaceId: "default-workspace",
                watchItemId: "watch-pipeline-input",
                agentId: "coder-agent",
                agentName: "Coder Agent",
                title: "Daily Project & Activity Digest",
                subtitle: "Summary of code refactoring & pipeline executions",
                category: .digest,
                content: """
                # 📈 Daily Project & Activity Digest
                **Date:** Today | **Agent:** Coder Agent

                ### 🛠️ Key Milestones Completed:
                - ✅ Implemented `WatchItem` models & directory monitoring pipeline
                - ✅ Integrated Claude Co-Work style artifact synthesis engine
                - ✅ Added Watch Folders navigation tab and Settings management hub
                - ✅ Verified pure Swift & Apple Silicon zero-electron performance footprint

                ### 📋 System Verification:
                - Memory footprint: ~48 MB RAM
                - Binary size: ~8.5 MB native Mach-O
                - Compilation status: 0 errors, 0 warnings
                """,
                format: "markdown",
                sourceTrigger: "Watch Folder: Staged Ingestion Pipeline"
            )
        ]
    }

    public func loadArtifacts() -> [AutomationArtifact] {
        if let items = storage.load([AutomationArtifact].self, from: "automation_artifacts.json"), !items.isEmpty {
            return items
        }
        let defaults = defaultArtifacts
        saveArtifacts(defaults)
        return defaults
    }

    public func saveArtifacts(_ artifacts: [AutomationArtifact]) {
        storage.save(artifacts, to: "automation_artifacts.json")
    }
}

/// Writes `sessions.json` off the calling thread. A burst of saves costs one write per snapshot
/// the queue actually reaches: a newer snapshot replaces an older one still waiting.
final class SessionWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftOpenWork.sessions-write", qos: .utility)
    private let lock = NSLock()
    private var pending: [Session]?

    func save(_ sessions: [Session], with storage: StorageService) {
        lock.lock()
        let alreadyScheduled = pending != nil
        pending = sessions
        lock.unlock()
        guard !alreadyScheduled else { return }
        queue.async { [self] in
            lock.lock()
            let snapshot = pending
            pending = nil
            lock.unlock()
            if let snapshot { storage.save(snapshot, to: "sessions.json") }
        }
    }

    func flush() {
        queue.sync {}
    }
}
