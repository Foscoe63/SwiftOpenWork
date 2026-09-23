import Foundation

public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark = "dark"
    case light = "light"
    case system = "system"
    case midnight = "midnight"
    case cyberpunk = "cyberpunk"
    case monokai = "monokai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "Dark (Default)"
        case .light: return "Light"
        case .system: return "Match System"
        case .midnight: return "Midnight Deep Blue"
        case .cyberpunk: return "Cyberpunk Neon"
        case .monokai: return "Monokai Pro"
        }
    }
}

public enum AccentColorChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case purple = "purple"
    case blue = "blue"
    case green = "green"
    case amber = "amber"
    case coral = "coral"
    case cyan = "cyan"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .purple: return "SwiftOpenWork Purple"
        case .blue: return "Electric Blue"
        case .green: return "Emerald Green"
        case .amber: return "Amber Gold"
        case .coral: return "Coral Sunset"
        case .cyan: return "Cyber Cyan"
        }
    }

    public var hex: String {
        switch self {
        case .purple: return "#8B5CF6"
        case .blue: return "#3B82F6"
        case .green: return "#10B981"
        case .amber: return "#F59E0B"
        case .coral: return "#F43F5E"
        case .cyan: return "#06B6D4"
        }
    }
}

public enum TerminalSafetyLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysAsk = "alwaysAsk"
    case safeOnly = "safeOnly"
    case allowAll = "allowAll"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alwaysAsk: return "Always Ask Confirmation"
        case .safeOnly: return "Allow Safe Read-Only Commands"
        case .allowAll: return "Unrestricted (Developer Mode)"
        }
    }
}

public enum MCPTransportType: String, Codable, CaseIterable, Identifiable, Sendable {
    case stdio = "stdio"
    case httpSse = "http_sse"
    case websocket = "websocket"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stdio: return "Standard IO (stdio Process)"
        case .httpSse: return "HTTP / Server-Sent Events (SSE)"
        case .websocket: return "WebSocket (ws/wss)"
        }
    }

    public var icon: String {
        switch self {
        case .stdio: return "terminal.fill"
        case .httpSse: return "network"
        case .websocket: return "arrow.left.arrow.right"
        }
    }
}

public struct MCPServerConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var transportType: MCPTransportType
    public var command: String
    public var args: [String]
    public var workingDirectory: String
    public var url: String
    public var headers: [String: String]
    public var env: [String: String]
    public var isEnabled: Bool
    /// Advertised tool names turned off individually while the server itself stays enabled.
    /// Storing the *disabled* names (rather than the enabled ones) means tools a server adds
    /// later are exposed by default instead of silently hidden. See `MCPToolGate`.
    public var disabledTools: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        transportType: MCPTransportType = .stdio,
        command: String = "npx",
        args: [String] = [],
        workingDirectory: String = "",
        url: String = "",
        headers: [String: String] = [:],
        env: [String: String] = [:],
        isEnabled: Bool = true,
        disabledTools: [String] = []
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.url = url
        self.headers = headers
        self.env = env
        self.isEnabled = isEnabled
        self.disabledTools = disabledTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "MCP Server"
        self.transportType = try container.decodeIfPresent(MCPTransportType.self, forKey: .transportType) ?? .stdio
        self.command = try container.decodeIfPresent(String.self, forKey: .command) ?? "npx"
        self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.disabledTools = try container.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// Which migrations have already run against this file. See `AppSettings.currentSchemaVersion`.
    public var settingsSchemaVersion: Int

    // General
    public var defaultWorkspaceId: String
    public var defaultAgentId: String
    public var defaultProviderId: String
    public var defaultModelId: String
    public var startOnLogin: Bool

    // Preferences
    public var defaultTemperature: Double
    public var defaultMaxTokens: Int
    public var defaultTopP: Double
    public var defaultPresencePenalty: Double
    public var defaultFrequencyPenalty: Double
    public var defaultRepeatPenalty: Double
    public var autoAdjustPenaltiesForLocalModels: Bool
    public var autoLoopBreakerEnabled: Bool
    public var defaultReasoningEffort: ReasoningEffort
    public var autoCompactContext: Bool
    public var contextCompactionThresholdTokens: Int
    public var planModeEnabled: Bool
    public var maxTurnTokens: Int
    public var playNotificationSounds: Bool

    // Permissions & Shell
    public var authorizedFolders: [String]
    public var terminalSafetyLevel: TerminalSafetyLevel
    public var terminalShell: String // e.g. "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"
    public var allowWebAccess: Bool
    /// Ask before `fetch_url` reaches a host this session has not used. Local and private-network
    /// addresses ask every time while this is on. Off restores unasked fetches, for automations
    /// that must fetch unattended.
    public var askBeforeFetchingNewSites: Bool
    public var sandboxAgentFileSystem: Bool

    // Appearance
    public var theme: AppTheme
    public var accentColor: AccentColorChoice
    public var editorFontSize: Int
    /// Ghost-text suggestions in the code editor while you type.
    public var inlineSuggestionsEnabled: Bool
    /// The provider and model that write them. Empty means automatic: the chat model, but only
    /// when it runs on this Mac — code is sent to a cloud model only when one is chosen here.
    public var inlineSuggestionProviderId: String
    public var inlineSuggestionModelId: String
    public var useTranslucentBackground: Bool
    public var compactSidebar: Bool

    // Multi-Agent & Orchestration
    public var allowSubAgentCreation: Bool
    public var maxGlobalSubAgentDepth: Int
    public var maxAutonomousIterations: Int
    /// Rounds a sub-agent started by `agent_spawn` gets before it must report back. Separate from
    /// `maxAutonomousIterations` so delegated work can stay cheaper than the lead's own turn.
    public var subAgentStepBudget: Int
    /// Minutes of work a sub-agent gets before it stops and reports what it has. A round still
    /// generating at the deadline is cancelled; time queued behind other generations on the local
    /// engine does not count.
    public var subAgentTimeoutMinutes: Int
    /// When a turn ends with tracked todos still pending and the reply is not a question, send
    /// another Continue automatically instead of waiting for the user to type one. See
    /// `AutoContinuePolicy`.
    public var autoContinueUntilDone: Bool
    public var showInterAgentCommunicationLogs: Bool
    public var enableAgentCollaborationRoom: Bool

    // MCP & Extensions
    public var mcpServers: [MCPServerConfig]
    public var voiceInputEnabled: Bool
    public var voiceSynthesisEnabled: Bool
    public var speechVoiceIdentifier: String
    public var imageGenerationEnabled: Bool

    // Google Integrations (secrets live in Keychain; these are non-secret toggles/metadata)
    public var googleAccountEmail: String
    public var gmailExtensionEnabled: Bool
    public var googleCalendarExtensionEnabled: Bool

    // MLX Local Runtime & External Models (GrizzyClaw & Osaurus Parity)
    public var customMLXModelsDirectory: String
    public var scanHuggingFaceCache: Bool
    public var scanLMStudioModels: Bool
    public var customHFCachePath: String
    public var autoLoadTopMLXModelOnLaunch: Bool
    public var mlxGpuMemoryBudgetRatio: Double

    // Environment
    public var customEnvironmentVariables: [String: String]

    // Updates & Debug
    public var autoCheckForUpdates: Bool
    public var developerMode: Bool
    public var verboseLogging: Bool

    /// Bumped when a stored settings.json needs fixing up rather than merely decoding.
    ///
    /// Version 2 turns the two voice toggles on for files written before they controlled
    /// anything. Both shipped defaulting to `false` while the mic button in the composer and the
    /// speak button on every assistant message were drawn unconditionally, so a stored `false` is
    /// not a preference anyone expressed — it is the default of a switch that was never wired.
    /// Honouring it literally would delete a working feature from every existing install.
    public static let currentSchemaVersion = 2

    public static var defaultMCPServers: [MCPServerConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let workspaceMain = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath + "/Main")
        return [
            MCPServerConfig(
                id: "mcp-filesystem",
                name: "Filesystem MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem", workspaceMain],
                workingDirectory: workspaceMain,
                isEnabled: false
            ),
            MCPServerConfig(
                id: "mcp-fetch",
                name: "Web Fetch MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-fetch"],
                isEnabled: false
            ),
            MCPServerConfig(
                id: "mcp-memory",
                name: "Memory Graph MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-memory"],
                isEnabled: false
            ),
            MCPServerConfig(
                id: "mcp-git",
                name: "Git Repository MCP",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-git", "--repository", workspaceMain],
                workingDirectory: workspaceMain,
                isEnabled: false
            ),
            MCPServerConfig(
                id: "mcp-macuse",
                name: "MacUse",
                transportType: .stdio,
                command: "npx",
                args: ["-y", "macuse-mcp"],
                workingDirectory: workspaceMain,
                isEnabled: false
            )
        ]
    }

    public init(
        settingsSchemaVersion: Int = AppSettings.currentSchemaVersion,
        defaultWorkspaceId: String = "default-workspace",
        defaultAgentId: String = "lead-assistant",
        // The built-in Apple Silicon MLX engine, which is what `defaultProviders` marks
        // `isDefault: true`. These two used to disagree: the provider list said the built-in
        // engine was the default while this said Ollama, so a fresh install pointed at a separate
        // app that may not be installed rather than the engine that ships in the binary and needs
        // nothing. Worse, when that Ollama provider was disabled the selection fell through to
        // whatever happened to be enabled first — a cloud provider, on the machine where this was
        // found, answering turns the user believed were local.
        defaultProviderId: String = "builtin-mlx-local",
        // The smallest curated model, matching the `isDefault` model in `defaultProviders`.
        defaultModelId: String = "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
        startOnLogin: Bool = false,
        defaultTemperature: Double = 0.7,
        defaultMaxTokens: Int = 4096,
        defaultTopP: Double = 1.0,
        defaultPresencePenalty: Double = 0.35,
        defaultFrequencyPenalty: Double = 0.35,
        defaultRepeatPenalty: Double = 1.25,
        autoAdjustPenaltiesForLocalModels: Bool = true,
        autoLoopBreakerEnabled: Bool = true,
        defaultReasoningEffort: ReasoningEffort = .medium,
        autoCompactContext: Bool = true,
        contextCompactionThresholdTokens: Int = 32000,
        planModeEnabled: Bool = false,
        maxTurnTokens: Int = 2_000_000,
        playNotificationSounds: Bool = true,
        // Only the workspace is reachable unless the user adds folders. This was the whole home
        // directory, which made the file sandbox cover everything a credential lives in.
        // Existing installs keep their stored list.
        authorizedFolders: [String] = [],
        terminalSafetyLevel: TerminalSafetyLevel = .safeOnly,
        terminalShell: String = "/bin/zsh",
        allowWebAccess: Bool = true,
        askBeforeFetchingNewSites: Bool = true,
        // Secure by default. Existing installs keep whatever they have: settings.json already
        // carries this key, and decoding prefers the stored value over this default.
        sandboxAgentFileSystem: Bool = true,
        theme: AppTheme = .dark,
        accentColor: AccentColorChoice = .purple,
        editorFontSize: Int = 14,
        inlineSuggestionsEnabled: Bool = true,
        inlineSuggestionProviderId: String = "",
        inlineSuggestionModelId: String = "",
        useTranslucentBackground: Bool = true,
        compactSidebar: Bool = false,
        allowSubAgentCreation: Bool = true,
        maxGlobalSubAgentDepth: Int = 3,
        maxAutonomousIterations: Int = 25,
        subAgentStepBudget: Int = 8,
        subAgentTimeoutMinutes: Int = 5,
        autoContinueUntilDone: Bool = true,
        showInterAgentCommunicationLogs: Bool = false,
        enableAgentCollaborationRoom: Bool = false,
        mcpServers: [MCPServerConfig] = defaultMCPServers,
        // Both features are built and reachable — the mic button in `ComposerView` and the
        // speak button in `MessageBubbleView`. These defaulted to `false` only because nothing
        // read them; now that they gate those buttons, the default has to match the behaviour
        // the app has always had, or wiring the switch would amount to removing the feature.
        voiceInputEnabled: Bool = true,
        voiceSynthesisEnabled: Bool = true,
        // Empty means "whatever macOS picks for the system language".
        //
        // This used to ship as `com.apple.speech.synthesis.voice.Alex`, which is an
        // *NSSpeechSynthesizer* identifier. Speech here goes through AVSpeechSynthesizer, whose
        // identifiers look like `com.apple.voice.compact.en-US.Samantha` — so the shipped default
        // matched none of the 186 voices installed on this Mac. Nothing noticed while the field
        // was unread; the moment it gained a picker, that picker rendered blank, because a
        // SwiftUI Picker whose selection matches no tag shows nothing at all.
        speechVoiceIdentifier: String = "",
        imageGenerationEnabled: Bool = true,
        googleAccountEmail: String = "",
        gmailExtensionEnabled: Bool = false,
        googleCalendarExtensionEnabled: Bool = false,
        // Was `/Volumes/Storage/Models` if that path happened to exist — one developer's volume
        // layout, shipped as a default. `knownMLXSearchRoots` already sweeps the mounted volumes
        // for the usual library folder names, which is how the real library here
        // (`/Volumes/Models/Models`) is found with this field empty. Set it only for a library
        // somewhere the sweep does not look.
        customMLXModelsDirectory: String = "",
        scanHuggingFaceCache: Bool = true,
        scanLMStudioModels: Bool = true,
        customHFCachePath: String = "",
        autoLoadTopMLXModelOnLaunch: Bool = false,
        mlxGpuMemoryBudgetRatio: Double = 0.75,
        customEnvironmentVariables: [String: String] = ["SWIFTOPENWORK_ENV": "development"],
        autoCheckForUpdates: Bool = true,
        developerMode: Bool = true,
        verboseLogging: Bool = false
    ) {
        self.settingsSchemaVersion = settingsSchemaVersion
        self.defaultWorkspaceId = defaultWorkspaceId
        self.defaultAgentId = defaultAgentId
        self.defaultProviderId = defaultProviderId
        self.defaultModelId = defaultModelId
        self.startOnLogin = startOnLogin
        self.defaultTemperature = defaultTemperature
        self.defaultMaxTokens = defaultMaxTokens
        self.defaultTopP = defaultTopP
        self.defaultPresencePenalty = defaultPresencePenalty
        self.defaultFrequencyPenalty = defaultFrequencyPenalty
        self.defaultRepeatPenalty = defaultRepeatPenalty
        self.autoAdjustPenaltiesForLocalModels = autoAdjustPenaltiesForLocalModels
        self.autoLoopBreakerEnabled = autoLoopBreakerEnabled
        self.defaultReasoningEffort = defaultReasoningEffort
        self.autoCompactContext = autoCompactContext
        self.contextCompactionThresholdTokens = contextCompactionThresholdTokens
        self.planModeEnabled = planModeEnabled
        self.maxTurnTokens = maxTurnTokens
        self.playNotificationSounds = playNotificationSounds
        self.authorizedFolders = authorizedFolders
        self.terminalSafetyLevel = terminalSafetyLevel
        self.terminalShell = terminalShell
        self.allowWebAccess = allowWebAccess
        self.askBeforeFetchingNewSites = askBeforeFetchingNewSites
        self.sandboxAgentFileSystem = sandboxAgentFileSystem
        self.theme = theme
        self.accentColor = accentColor
        self.editorFontSize = editorFontSize
        self.inlineSuggestionsEnabled = inlineSuggestionsEnabled
        self.inlineSuggestionProviderId = inlineSuggestionProviderId
        self.inlineSuggestionModelId = inlineSuggestionModelId
        self.useTranslucentBackground = useTranslucentBackground
        self.compactSidebar = compactSidebar
        self.allowSubAgentCreation = allowSubAgentCreation
        self.maxGlobalSubAgentDepth = maxGlobalSubAgentDepth
        self.maxAutonomousIterations = maxAutonomousIterations
        self.subAgentStepBudget = subAgentStepBudget
        self.subAgentTimeoutMinutes = subAgentTimeoutMinutes
        self.autoContinueUntilDone = autoContinueUntilDone
        self.showInterAgentCommunicationLogs = showInterAgentCommunicationLogs
        self.enableAgentCollaborationRoom = enableAgentCollaborationRoom
        self.mcpServers = mcpServers.isEmpty ? AppSettings.defaultMCPServers : mcpServers
        self.voiceInputEnabled = voiceInputEnabled
        self.voiceSynthesisEnabled = voiceSynthesisEnabled
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.imageGenerationEnabled = imageGenerationEnabled
        self.googleAccountEmail = googleAccountEmail
        self.gmailExtensionEnabled = gmailExtensionEnabled
        self.googleCalendarExtensionEnabled = googleCalendarExtensionEnabled
        self.customMLXModelsDirectory = customMLXModelsDirectory
        self.scanHuggingFaceCache = scanHuggingFaceCache
        self.scanLMStudioModels = scanLMStudioModels
        self.customHFCachePath = customHFCachePath
        self.autoLoadTopMLXModelOnLaunch = autoLoadTopMLXModelOnLaunch
        self.mlxGpuMemoryBudgetRatio = mlxGpuMemoryBudgetRatio
        self.customEnvironmentVariables = customEnvironmentVariables
        self.autoCheckForUpdates = autoCheckForUpdates
        self.developerMode = developerMode
        self.verboseLogging = verboseLogging
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = AppSettings.default

        // Absent means a file written before this key existed, so it is version 1 and has not
        // been migrated — *not* the current version. `def` cannot be the fallback here.
        self.settingsSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .settingsSchemaVersion) ?? 1

        self.defaultWorkspaceId = try container.decodeIfPresent(String.self, forKey: .defaultWorkspaceId) ?? def.defaultWorkspaceId
        self.defaultAgentId = try container.decodeIfPresent(String.self, forKey: .defaultAgentId) ?? def.defaultAgentId
        self.defaultProviderId = try container.decodeIfPresent(String.self, forKey: .defaultProviderId) ?? def.defaultProviderId
        self.defaultModelId = try container.decodeIfPresent(String.self, forKey: .defaultModelId) ?? def.defaultModelId
        self.startOnLogin = try container.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? def.startOnLogin

        self.defaultTemperature = try container.decodeIfPresent(Double.self, forKey: .defaultTemperature) ?? def.defaultTemperature
        self.defaultMaxTokens = try container.decodeIfPresent(Int.self, forKey: .defaultMaxTokens) ?? def.defaultMaxTokens
        self.defaultTopP = try container.decodeIfPresent(Double.self, forKey: .defaultTopP) ?? def.defaultTopP
        self.defaultPresencePenalty = try container.decodeIfPresent(Double.self, forKey: .defaultPresencePenalty) ?? def.defaultPresencePenalty
        self.defaultFrequencyPenalty = try container.decodeIfPresent(Double.self, forKey: .defaultFrequencyPenalty) ?? def.defaultFrequencyPenalty
        self.defaultRepeatPenalty = try container.decodeIfPresent(Double.self, forKey: .defaultRepeatPenalty) ?? def.defaultRepeatPenalty
        self.autoAdjustPenaltiesForLocalModels = try container.decodeIfPresent(Bool.self, forKey: .autoAdjustPenaltiesForLocalModels) ?? def.autoAdjustPenaltiesForLocalModels
        self.autoLoopBreakerEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoLoopBreakerEnabled) ?? def.autoLoopBreakerEnabled
        self.defaultReasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .defaultReasoningEffort) ?? def.defaultReasoningEffort
        self.autoCompactContext = try container.decodeIfPresent(Bool.self, forKey: .autoCompactContext) ?? def.autoCompactContext
        self.contextCompactionThresholdTokens = try container.decodeIfPresent(Int.self, forKey: .contextCompactionThresholdTokens) ?? def.contextCompactionThresholdTokens
        self.planModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .planModeEnabled) ?? false
        self.maxTurnTokens = try container.decodeIfPresent(Int.self, forKey: .maxTurnTokens) ?? 2_000_000
        self.playNotificationSounds = try container.decodeIfPresent(Bool.self, forKey: .playNotificationSounds) ?? def.playNotificationSounds

        self.authorizedFolders = try container.decodeIfPresent([String].self, forKey: .authorizedFolders) ?? def.authorizedFolders
        self.terminalSafetyLevel = try container.decodeIfPresent(TerminalSafetyLevel.self, forKey: .terminalSafetyLevel) ?? def.terminalSafetyLevel
        self.terminalShell = try container.decodeIfPresent(String.self, forKey: .terminalShell) ?? def.terminalShell
        self.allowWebAccess = try container.decodeIfPresent(Bool.self, forKey: .allowWebAccess) ?? def.allowWebAccess
        self.askBeforeFetchingNewSites = try container.decodeIfPresent(Bool.self, forKey: .askBeforeFetchingNewSites) ?? def.askBeforeFetchingNewSites
        self.sandboxAgentFileSystem = try container.decodeIfPresent(Bool.self, forKey: .sandboxAgentFileSystem) ?? def.sandboxAgentFileSystem

        self.theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? def.theme
        self.accentColor = try container.decodeIfPresent(AccentColorChoice.self, forKey: .accentColor) ?? def.accentColor
        self.editorFontSize = try container.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? def.editorFontSize
        self.inlineSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .inlineSuggestionsEnabled) ?? def.inlineSuggestionsEnabled
        self.inlineSuggestionProviderId = try container.decodeIfPresent(String.self, forKey: .inlineSuggestionProviderId) ?? def.inlineSuggestionProviderId
        self.inlineSuggestionModelId = try container.decodeIfPresent(String.self, forKey: .inlineSuggestionModelId) ?? def.inlineSuggestionModelId
        self.useTranslucentBackground = try container.decodeIfPresent(Bool.self, forKey: .useTranslucentBackground) ?? def.useTranslucentBackground
        self.compactSidebar = try container.decodeIfPresent(Bool.self, forKey: .compactSidebar) ?? def.compactSidebar

        self.allowSubAgentCreation = try container.decodeIfPresent(Bool.self, forKey: .allowSubAgentCreation) ?? def.allowSubAgentCreation
        self.maxGlobalSubAgentDepth = try container.decodeIfPresent(Int.self, forKey: .maxGlobalSubAgentDepth) ?? def.maxGlobalSubAgentDepth
        self.maxAutonomousIterations = try container.decodeIfPresent(Int.self, forKey: .maxAutonomousIterations) ?? def.maxAutonomousIterations
        self.subAgentStepBudget = try container.decodeIfPresent(Int.self, forKey: .subAgentStepBudget) ?? def.subAgentStepBudget
        self.subAgentTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .subAgentTimeoutMinutes) ?? def.subAgentTimeoutMinutes
        self.autoContinueUntilDone = try container.decodeIfPresent(Bool.self, forKey: .autoContinueUntilDone) ?? def.autoContinueUntilDone
        self.showInterAgentCommunicationLogs = try container.decodeIfPresent(Bool.self, forKey: .showInterAgentCommunicationLogs) ?? def.showInterAgentCommunicationLogs
        self.enableAgentCollaborationRoom = try container.decodeIfPresent(Bool.self, forKey: .enableAgentCollaborationRoom) ?? def.enableAgentCollaborationRoom

        let decodedMcp = try container.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        self.mcpServers = decodedMcp.isEmpty ? AppSettings.defaultMCPServers : decodedMcp

        self.voiceInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceInputEnabled) ?? def.voiceInputEnabled
        self.voiceSynthesisEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceSynthesisEnabled) ?? def.voiceSynthesisEnabled
        self.speechVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier) ?? def.speechVoiceIdentifier
        self.imageGenerationEnabled = try container.decodeIfPresent(Bool.self, forKey: .imageGenerationEnabled) ?? def.imageGenerationEnabled

        self.googleAccountEmail = try container.decodeIfPresent(String.self, forKey: .googleAccountEmail) ?? def.googleAccountEmail
        self.gmailExtensionEnabled = try container.decodeIfPresent(Bool.self, forKey: .gmailExtensionEnabled) ?? def.gmailExtensionEnabled
        self.googleCalendarExtensionEnabled = try container.decodeIfPresent(Bool.self, forKey: .googleCalendarExtensionEnabled) ?? def.googleCalendarExtensionEnabled

        self.customMLXModelsDirectory = try container.decodeIfPresent(String.self, forKey: .customMLXModelsDirectory) ?? def.customMLXModelsDirectory
        self.scanHuggingFaceCache = try container.decodeIfPresent(Bool.self, forKey: .scanHuggingFaceCache) ?? def.scanHuggingFaceCache
        self.scanLMStudioModels = try container.decodeIfPresent(Bool.self, forKey: .scanLMStudioModels) ?? def.scanLMStudioModels
        self.customHFCachePath = try container.decodeIfPresent(String.self, forKey: .customHFCachePath) ?? def.customHFCachePath
        self.autoLoadTopMLXModelOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoLoadTopMLXModelOnLaunch) ?? def.autoLoadTopMLXModelOnLaunch
        self.mlxGpuMemoryBudgetRatio = try container.decodeIfPresent(Double.self, forKey: .mlxGpuMemoryBudgetRatio) ?? def.mlxGpuMemoryBudgetRatio

        self.customEnvironmentVariables = try container.decodeIfPresent([String: String].self, forKey: .customEnvironmentVariables) ?? def.customEnvironmentVariables


        self.autoCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? def.autoCheckForUpdates
        self.developerMode = try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? def.developerMode
        self.verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? def.verboseLogging
    }

    public static var `default`: AppSettings {
        AppSettings()
    }
}
