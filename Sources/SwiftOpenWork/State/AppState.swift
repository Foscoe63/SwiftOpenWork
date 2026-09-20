import Foundation
import AppKit
import SwiftUI
import Combine
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

public enum NavigationDestination: String, CaseIterable, Identifiable {
    case chat = "chat"
    case localModels = "localModels"
    case agents = "agents"
    case providers = "providers"
    case automations = "automations"
    case watchFolders = "watchFolders"
    case artifacts = "artifacts"
    case memory = "memory"
    case tools = "tools"
    case dashboard = "dashboard"
    case settings = "settings"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: return "Chat & Sessions"
        case .localModels: return "Local Models"
        case .agents: return "AI Agents"
        case .providers: return "Model Providers"
        case .automations: return "Automations"
        case .watchFolders: return "Watch Folders"
        case .artifacts: return "Artifacts & Files"
        case .memory: return "Memory & Knowledge"
        case .tools: return "Tools & MCP"
        case .dashboard: return "Dashboard & Metrics"
        case .settings: return "Settings"
        }
    }

    public var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .localModels: return "cube.fill"
        case .agents: return "person.3.sequence.fill"
        case .providers: return "server.rack"
        case .automations: return "bolt.badge.clock.fill"
        case .watchFolders: return "eye.circle.fill"
        case .artifacts: return "folder.fill"
        case .memory: return "brain.head.profile"
        case .tools: return "hammer.fill"
        case .dashboard: return "chart.xyaxis.line"
        case .settings: return "gearshape.fill"
        }
    }
}

public enum InspectorTab: String, CaseIterable, Identifiable {
    /// First, because reading and fixing what the agent wrote is the loop the rest supports.
    case editor = "editor"
    case preview = "preview"
    case subagents = "subagents"
    case comms = "comms"
    case artifacts = "artifacts"
    case tools = "tools"
    case terminal = "terminal"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .editor: return "Editor"
        case .preview: return "Preview"
        case .subagents: return "Sub-Agent Tree"
        // "Agent Messages" was the only title wide enough to need shrinking in the tab bar,
        // which made it the smallest text in a row of equal-width tabs.
        case .comms: return "Messages"
        case .artifacts: return "Artifacts"
        case .tools: return "Tools"
        case .terminal: return "Terminal"
        }
    }

    public var icon: String {
        switch self {
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .preview: return "safari"
        case .subagents: return "point.3.connected.trianglepath.dotted"
        case .comms: return "bubble.left.and.exclamationmark.bubble.right.fill"
        case .artifacts: return "doc.text.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .terminal: return "terminal.fill"
        }
    }
}

/// An agent run in progress that the chat window did not start.
public struct BackgroundRun: Equatable, Sendable, Identifiable {
    public var sessionId: String
    public var title: String
    public var id: String { sessionId }

    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }

    /// The header's status line. Pure, for tests.
    public static func statusLine(chatIsGenerating: Bool, runs: [BackgroundRun]) -> String {
        let chat = chatIsGenerating ? "Agent executing..." : "Agent ready"
        guard let first = runs.first else { return chat }
        let others = runs.count > 1 ? " +\(runs.count - 1) more" : ""
        return "\(chat) · “\(first.title)”\(others) running in background"
    }
}

public struct QueuedComposerMessage: Equatable, Sendable {
    public var text: String
    public var attachments: [MessageAttachment]

    public init(text: String, attachments: [MessageAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // MARK: - Navigation & Layout
    @Published public var navigationDestination: NavigationDestination = WindowLayoutStore.navigationDestination {
        didSet { WindowLayoutStore.navigationDestination = navigationDestination }
    }
    @Published public var isInspectorOpen: Bool = WindowLayoutStore.isInspectorOpen {
        didSet { WindowLayoutStore.isInspectorOpen = isInspectorOpen }
    }
    @Published public var inspectorTab: InspectorTab = WindowLayoutStore.inspectorTab {
        didSet { WindowLayoutStore.inspectorTab = inspectorTab }
    }
    @Published public var settingsTab: String = WindowLayoutStore.settingsTab {
        didSet { WindowLayoutStore.settingsTab = settingsTab }
    }
    @Published public var searchSessionText: String = ""
    @Published public var isSearchDialogOpen: Bool = false
    @Published public var toastMessage: String? = nil

    // MARK: - Core Entities
    @Published public var workspaces: [Workspace] = []
    @Published public var activeWorkspaceId: String = "default-workspace" {
        didSet { WindowLayoutStore.workspaceId = activeWorkspaceId }
    }
    @Published public var sessions: [Session] = []
    @Published public var currentSessionId: String? = nil {
        didSet { WindowLayoutStore.sessionId = currentSessionId }
    }
    @Published public var agents: [Agent] = []
    @Published public var providers: [ModelProvider] = []
    @Published public var tools: [Tool] = []
    @Published public var skills: [Skill] = []
    @Published public var plugins: [AppExtensionPlugin] = []
    @Published public var memories: [MemoryItem] = []
    @Published public var automations: [Automation] = []
    @Published public var watchItems: [WatchItem] = []
    @Published public var artifacts: [AutomationArtifact] = []
    @Published public var settings: AppSettings = AppSettings.default {
        didSet {
            persistence.saveSettings(settings)
            // Switching the Agent Messages log off while its tab is selected would leave the
            // inspector on a tab that is no longer in the tab bar. Corrected here rather than in
            // the view, so nothing publishes a change during a view update.
            if !settings.showInterAgentCommunicationLogs, inspectorTab == .comms {
                inspectorTab = .tools
            }
        }
    }
    @Published public var interAgentMessages: [AgentMessage] = []
    @Published public var activeSubAgentTasks: [SubAgentTask] = []
    @Published public var localMLXModels: [LocalMLXModel] = []
    @Published public var isScanningMLX: Bool = false
    /// Model ids currently held in-process by NativeMLXService (Metal/RAM).
    @Published public var loadedMLXModelIds: [String] = []

    // MARK: - Runtime
    @Published public var isGenerating: Bool = false {
        // The turn may have rewritten files open in the editor. The poll would notice within a
        // second and a half; checking now means the tab is current the moment the reply lands.
        didSet { if oldValue && !isGenerating { EditorWorkspace.shared.checkAllAgainstDisk() } }
    }
    /// A width the inspector should grow to, set when something opens that needs room (the editor
    /// or the preview in a narrow inspector). MainView consumes and clears it.
    @Published public var inspectorWidthRequest: Double?
    /// Agent runs with no window driving them — automations, Shortcuts, Siri — in start order.
    /// `isGenerating` describes only the chat turn on screen.
    @Published public var backgroundRuns: [BackgroundRun] = []
    @Published public var composerText: String = ""
    /// Attachments offered to the composer from elsewhere — a preview screenshot or a picked
    /// element. The composer owns its attachment list, so it takes these and clears the inbox.
    @Published public var composerAttachmentInbox: [MessageAttachment] = []
    /// When a streaming reply last reached `sessions.json`; see `onMessageUpdated`.
    private var lastStreamingSessionSave = Date.distantPast
    /// Follow-up typed while a turn is running — sent automatically when the turn finishes.
    @Published public var queuedFollowUp: QueuedComposerMessage?
    /// Set by tool cards when the user wants the turn-change sheet; ChatView observes it.
    @Published public var presentTurnChangeReview: Bool = false
    /// Messages in the current session whose turn can be rewound. Held as a set so the transcript
    /// can decorate every row without an actor hop per message.
    @Published public var restorableMessageIds: Set<String> = []
    /// A restore the user has asked for but not yet confirmed. Nothing is written until they do.
    @Published public var pendingRestore: PendingRestore?
    @Published public var selectedAgentId: String = "lead-assistant"
    @Published public var selectedProviderId: String = "builtin-mlx-local"
    @Published public var selectedModelId: String = "llama3:latest"
    /// When the current turn began, so a finished one can say how long it took.
    private var turnStartedAt: Date?
    @Published public var isReasoningEnabled: Bool = true
    @Published public var pullModelProgress: Double = 0.0
    @Published public var pullModelStatusText: String = ""
    @Published public var isPullingModel: Bool = false
    private var currentExecutionTask: Task<Void, Never>? = nil
    private var mlxLoadedObserver: MLXLoadedModelsObserver?

    private let persistence = PersistenceManager.shared

    public init() {
        // Also done at app launch; repeated here for anything that creates the state without it.
        LocalInferenceWiring.install()
        // Before anything reads preferences or the Keychain: 1.1 stored them under another name.
        LegacyIdentityMigration.runIfNeeded()
        loadAll()
        EngineHosting.host = self
        recoverInterruptedAutomationRuns()
        mlxLoadedObserver = MLXLoadedModelsObserver { [weak self] in
            self?.refreshLoadedMLXModels()
        }
        refreshLoadedMLXModels()
    }

    deinit {
        currentExecutionTask?.cancel()
    }

    public func refreshLoadedMLXModels() {
        loadedMLXModelIds = NativeMLXService.shared.loadedModelIds
    }

    public func loadAll() {
        self.workspaces = persistence.loadWorkspaces()
        self.settings = persistence.loadSettings()
        // There used to be a block here that wrote "/Volumes/Storage/Models" into the user's
        // settings whenever that path existed and the field was empty — a hardcoded developer
        // volume, persisted into their configuration without asking. `knownMLXSearchRoots`
        // sweeps the mounted volumes for library folders already, so an empty field is not a
        // gap to be filled.
        self.providers = persistence.loadProviders()
        self.agents = persistence.loadAgents()
        self.sessions = persistence.loadSessions()
        self.tools = persistence.loadTools()
        self.skills = persistence.loadSkills()
        self.plugins = persistence.loadPlugins()
        self.memories = persistence.loadMemories()
        self.automations = persistence.loadAutomations()
        self.watchItems = persistence.loadWatchItems()
        self.artifacts = persistence.loadArtifacts()

        // Hydrate active workspace from settings / last-used layout
        if let savedWs = WindowLayoutStore.workspaceId,
           workspaces.contains(where: { $0.id == savedWs }) {
            self.activeWorkspaceId = savedWs
        } else if workspaces.contains(where: { $0.id == settings.defaultWorkspaceId }) {
            self.activeWorkspaceId = settings.defaultWorkspaceId
        } else if let firstWs = workspaces.first {
            self.activeWorkspaceId = firstWs.id
        }

        // Ensure default local providers (omlx, vmlx) exist in user configuration if upgraded
        let defaults = PersistenceManager.shared.defaultProviders
        for def in defaults {
            if !providers.contains(where: { $0.id == def.id || $0.kind == def.kind }) {
                providers.append(def)
            }
        }
        persistence.saveProviders(providers)

        // Ensure workspace folder exists
        ensureWorkspaceFolderExists(for: currentWorkspace)

        // Select last session when possible; otherwise first for active workspace
        let activeWsSessions = sessions.filter { $0.workspaceId == activeWorkspaceId && !$0.isArchived }
        let restoredSession: Session?
        if let savedSessionId = WindowLayoutStore.sessionId,
           let match = sessions.first(where: { $0.id == savedSessionId && !$0.isArchived }) {
            restoredSession = match
            if workspaces.contains(where: { $0.id == match.workspaceId }) {
                self.activeWorkspaceId = match.workspaceId
            }
        } else {
            restoredSession = activeWsSessions.first ?? sessions.first
        }

        if let first = restoredSession {
            self.currentSessionId = first.id
            self.selectedAgentId = first.agentId
            self.selectedProviderId = first.providerId.isEmpty ? settings.defaultProviderId : first.providerId
            self.selectedModelId = first.modelId.isEmpty ? settings.defaultModelId : first.modelId
            self.interAgentMessages = first.interAgentMessages
            self.activeSubAgentTasks = first.activeSubAgentTasks
            WindowLayoutStore.sessionId = first.id
            WindowLayoutStore.workspaceId = activeWorkspaceId
        } else {
            self.selectedProviderId = settings.defaultProviderId
            self.selectedModelId = settings.defaultModelId
        }

        // Validate selectedProviderId & selectedModelId are valid and present
        // Existence is not enough: a disabled provider passes that check and then fails every
        // turn against a server that is deliberately not running.
        self.selectedProviderId = ProviderSelection.correctedSelectionId(
            providers: providers,
            selectedId: selectedProviderId
        )
        let activeProv = currentProvider
        let isLocalMLX = localMLXModels.contains(where: { $0.id == selectedModelId }) || LocalMLXEngine.curatedModels.contains(where: { $0.id == selectedModelId })
        if !activeProv.models.contains(where: { $0.id == selectedModelId }) && !isLocalMLX {
            self.selectedModelId = activeProv.models.first?.id ?? "llama3:latest"
        }

        // Initialize active file monitors
        restartWatchEngine()
        
        // Sync MCP tools inventory
        syncMcpTools()

        // Scan local MLX models
        rescanMLXModels()

        if settings.autoLoadTopMLXModelOnLaunch {
            preloadDefaultMLXModel()
        }
    }

    /// Warm the in-process MLX model the next turn will most likely need.
    ///
    /// The first turn against a large local checkpoint pays minutes of loading while the user
    /// waits on an answer. Done at launch, that cost lands where nothing is blocked on it.
    ///
    /// Preloads the *configured* model rather than whichever is flagged a top pick: loading a
    /// model the user has not selected would spend tens of gigabytes of memory on a guess, and the
    /// turn would then load the real one anyway.
    private func preloadDefaultMLXModel() {
        let modelId = settings.defaultModelId
        guard !modelId.isEmpty else { return }
        // Only for the in-process path. A server-backed provider loads on its own side, and a
        // cloud model has nothing to load.
        let provider = providers.first { $0.id == settings.defaultProviderId }
        guard provider?.kind == .omlx || provider?.kind == .vmlx else { return }
        guard LocalMLXEngine.shared.resolveLocalModelDirectory(modelId: modelId, settings: settings) != nil else {
            // Not on disk. Preloading would start a multi-gigabyte download nobody asked for.
            return
        }
        NativeMLXService.shared.preload(modelId: modelId)
    }

    public var currentWorkspace: Workspace {
        workspaces.first(where: { $0.id == activeWorkspaceId }) ?? Workspace.default
    }

    public var currentSession: Session? {
        guard let id = currentSessionId else { return sessions.first }
        return sessions.first(where: { $0.id == id })
    }

    public var currentAgent: Agent {
        agents.first(where: { $0.id == selectedAgentId }) ?? agents.first ?? Agent(id: "default", name: "Assistant")
    }

    /// The provider resolution for this session, including whether the turn must be refused.
    public var currentProviderResolution: ProviderSelection.Resolution? {
        // Matching on id alone would hand back a provider the user switched off — the exact
        // state a stale `defaultProviderId` produces — and the fallback below would never run.
        ProviderSelection.resolve(providers: providers, selectedId: selectedProviderId)
    }

    public var currentProvider: ModelProvider {
        currentProviderResolution?.provider
            ?? ModelProvider(name: "Default", type: .local, kind: .ollama)
    }

    public var currentModel: ModelInfo {
        let prov = currentProvider
        if let found = prov.models.first(where: { $0.id == selectedModelId }) {
            return found
        }
        if let local = localMLXModels.first(where: { $0.id == selectedModelId }) ?? LocalMLXEngine.curatedModels.first(where: { $0.id == selectedModelId }) {
            return ModelInfo(
                id: local.id,
                name: "\(local.name) (\(local.quantization ?? "MLX"))",
                providerId: prov.id,
                contextWindow: local.contextWindow ?? 131072,
                supportsVision: local.isVLM,
                supportsReasoning: local.useCase == .reasoning,
                supportsStreaming: true,
                supportsTools: true,
                description: local.description,
                isDefault: local.isTopPick,
                speedTier: local.useCase == .fast ? "Fast" : "Powerful"
            )
        }
        return prov.models.first ?? ModelInfo(id: selectedModelId, name: selectedModelId)
    }

    public func selectLocalMLXModel(_ model: LocalMLXModel) {
        // Free GPU/RAM from any previously loaded in-process model before switching.
        let previouslyLoaded = NativeMLXService.shared.loadedModelIds.filter { $0 != model.id }
        if !previouslyLoaded.isEmpty {
            _ = NativeMLXService.shared.unloadAll()
            // Keep the newly selected id unloaded until first chat turn loads it.
            refreshLoadedMLXModels()
        }

        // Ensure Apple Silicon built-in provider exists and is enabled
        if let omlxIdx = providers.firstIndex(where: { $0.kind == .omlx }) {
            providers[omlxIdx].isEnabled = true
            providers[omlxIdx].name = "Apple Silicon (Built-in)"
            selectedProviderId = providers[omlxIdx].id

            // Ensure model info exists in provider's model list
            if !providers[omlxIdx].models.contains(where: { $0.id == model.id }) {
                let info = ModelInfo(
                    id: model.id,
                    name: "\(model.name) (\(model.quantization ?? "MLX"))",
                    providerId: providers[omlxIdx].id,
                    contextWindow: model.contextWindow ?? 131072,
                    supportsVision: model.isVLM,
                    supportsReasoning: model.useCase == .reasoning,
                    supportsStreaming: true,
                    supportsTools: true,
                    description: model.description,
                    isDefault: model.isTopPick,
                    speedTier: model.useCase == .fast ? "Fast" : "Powerful"
                )
                providers[omlxIdx].models.append(info)
                persistence.saveProviders(providers)
            }
        } else {
            let newOmlx = ModelProvider(
                id: "builtin-mlx-local",
                name: "Apple Silicon (Built-in)",
                type: .local,
                kind: .omlx,
                baseUrl: "http://127.0.0.1:8000/v1",
                isEnabled: true,
                models: [
                    ModelInfo(
                        id: model.id,
                        name: "\(model.name) (\(model.quantization ?? "MLX"))",
                        providerId: "builtin-mlx-local",
                        contextWindow: model.contextWindow ?? 131072,
                        supportsVision: model.isVLM,
                        supportsReasoning: model.useCase == .reasoning,
                        supportsStreaming: true,
                        supportsTools: true,
                        description: model.description,
                        isDefault: true,
                        speedTier: "Fast"
                    )
                ]
            )
            providers.append(newOmlx)
            selectedProviderId = newOmlx.id
            persistence.saveProviders(providers)
        }

        selectedModelId = model.id

        // Update active session with the selected model
        if var curr = currentSession {
            curr.providerId = selectedProviderId
            curr.modelId = selectedModelId
            if let idx = sessions.firstIndex(where: { $0.id == curr.id }) {
                sessions[idx] = curr
                persistence.saveSessions(sessions)
            }
        }

        if previouslyLoaded.isEmpty {
            showToast("Active model: \(model.name)")
        } else {
            showToast("Switched to \(model.name) — previous model unloaded from memory")
        }
    }

    /// Unload one in-process MLX model from Metal/RAM.
    public func unloadMLXModel(id modelId: String) {
        let unloaded = NativeMLXService.shared.unload(modelId: modelId)
        refreshLoadedMLXModels()
        if unloaded {
            let name = localMLXModels.first(where: { $0.id == modelId })?.name ?? modelId
            showToast("Unloaded \(name) from memory")
        } else {
            showToast("Model was not loaded in memory")
        }
    }

    /// Unload every in-process MLX model.
    public func unloadAllMLXModels() {
        let count = NativeMLXService.shared.unloadAll()
        refreshLoadedMLXModels()
        if count > 0 {
            showToast("Unloaded \(count) model\(count == 1 ? "" : "s") from memory")
        } else {
            showToast("No models currently loaded in memory")
        }
    }

    /// Switch to a non-MLX provider model and persist the choice on the active session.
    public func selectProviderModel(providerId: String, modelId: String) {
        guard providers.contains(where: { $0.id == providerId }) else { return }
        // Leaving built-in MLX — free any in-process weights.
        if currentProvider.kind == .omlx || currentProvider.kind == .vmlx {
            _ = NativeMLXService.shared.unloadAll()
            refreshLoadedMLXModels()
        }
        selectedProviderId = providerId
        selectedModelId = modelId

        if var curr = currentSession {
            curr.providerId = providerId
            curr.modelId = modelId
            if let idx = sessions.firstIndex(where: { $0.id == curr.id }) {
                sessions[idx] = curr
                persistence.saveSessions(sessions)
            }
        }

        let name = providers.first(where: { $0.id == providerId })?.models.first(where: { $0.id == modelId })?.name
            ?? modelId
        showToast("Active model: \(name)")
    }

    // MARK: - Sessions Operations
    public func createNewSession(agentId: String? = nil) {
        // Settings' default agent is the fallback when the selection no longer names a real
        // agent — previously the setting existed and nothing ever read it.
        let fallbackAgent = agents.contains(where: { $0.id == selectedAgentId })
            ? selectedAgentId
            : (agents.contains(where: { $0.id == settings.defaultAgentId }) ? settings.defaultAgentId : selectedAgentId)
        let chosenAgent = agentId ?? fallbackAgent
        let newSession = Session(
            workspaceId: activeWorkspaceId,
            title: "New Session",
            agentId: chosenAgent,
            providerId: selectedProviderId,
            modelId: selectedModelId,
            messages: []
        )
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        interAgentMessages.removeAll()
        activeSubAgentTasks.removeAll()
        persistence.saveSessions(sessions)
        navigationDestination = .chat

        // `.onSessionCreated` automations fire here. `HeadlessAgentTurn` builds its session
        // directly rather than calling this method, so an automation cannot trigger itself.
        AutomationScheduler.shared.sessionWasCreated()
    }

    /// Branch the current session at `messageId` into a new one, and switch to it.
    ///
    /// Only the conversation branches. See `SessionFork` for why the working tree deliberately does
    /// not, and how the fork says so rather than pretending otherwise.
    @discardableResult
    public func forkSession(_ session: Session, at messageId: String) -> Session? {
        guard let outcome = SessionFork.fork(session, at: messageId) else {
            showToast("Nothing after this message to fork away from")
            return nil
        }
        sessions.insert(outcome.session, at: 0)
        persistence.saveSessions(sessions)
        selectSession(outcome.session)
        navigationDestination = .chat

        if outcome.divergedFiles.isEmpty {
            showToast("Forked to '\(outcome.session.title)'")
        } else {
            // Naming the count here, not just in the transcript: a user who forks and immediately
            // types a new instruction should not first have to notice a note.
            showToast("Forked — \(outcome.divergedFiles.count) file(s) changed after this point are still on disk")
        }
        return outcome.session
    }

    public func selectSession(_ session: Session) {
        currentSessionId = session.id
        refreshRestorePoints()
        selectedAgentId = session.agentId
        if !session.providerId.isEmpty { selectedProviderId = session.providerId }
        if !session.modelId.isEmpty { selectedModelId = session.modelId }
        interAgentMessages = session.interAgentMessages
        activeSubAgentTasks = session.activeSubAgentTasks
        // Keep chat header + sidebar workspace pickers aligned with the session.
        if workspaces.contains(where: { $0.id == session.workspaceId }),
           activeWorkspaceId != session.workspaceId {
            activeWorkspaceId = session.workspaceId
            settings.defaultWorkspaceId = session.workspaceId
            persistence.saveSettings(settings)
        }
    }

    /// Assign the active chat session to a workspace and sync `activeWorkspaceId`
    /// (sidebar "Core Workspaces & Research" + chat header stay in lockstep).
    public func assignCurrentSessionWorkspace(to workspaceId: String) {
        guard let target = workspaces.first(where: { $0.id == workspaceId }) else { return }

        activeWorkspaceId = target.id
        settings.defaultWorkspaceId = target.id
        persistence.saveSettings(settings)
        ensureWorkspaceFolderExists(for: target)

        if let assignedAgentId = target.assignedAgentId, agents.contains(where: { $0.id == assignedAgentId }) {
            selectedAgentId = assignedAgentId
        }

        if var session = currentSession, let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            session.workspaceId = target.id
            if let assignedAgentId = target.assignedAgentId {
                session.agentId = assignedAgentId
            }
            sessions[idx] = session
            persistence.saveSessions(sessions)
            showToast("Session workspace: \(target.name)")
        } else {
            createNewSession(agentId: target.assignedAgentId ?? selectedAgentId)
            showToast("Switched to '\(target.name)'")
        }
    }

    public func deleteSession(_ session: Session) {
        sessions.removeAll(where: { $0.id == session.id })
        if currentSessionId == session.id {
            currentSessionId = sessions.first?.id
        }
        persistence.saveSessions(sessions)
        // Snapshots of a transcript nobody can open are just disk use.
        let id = session.id
        Task { await SessionCheckpointStore.shared.deleteAll(forSession: id) }
        refreshRestorePoints()
    }

    // MARK: - Restore points

    /// A restore the user has been shown but not yet agreed to.
    public struct PendingRestore: Identifiable, Sendable {
        public var id: String { checkpointId }
        public var checkpointId: String
        public var messageId: String
        public var label: String
        public var plan: SessionCheckpointStore.RestorePlan
    }

    public func refreshRestorePoints() {
        guard let id = currentSessionId else {
            restorableMessageIds = []
            return
        }
        Task { [weak self] in
            let ids = await SessionCheckpointStore.shared.restorableMessageIds(forSession: id)
            guard let self, self.currentSessionId == id else { return }
            self.restorableMessageIds = ids
        }
    }

    /// Work out what rewinding to a message would do, and show it. Writes nothing.
    public func prepareRestore(toMessageId messageId: String) {
        guard let sessionId = currentSessionId else { return }
        Task { [weak self] in
            guard let checkpoint = await SessionCheckpointStore.shared.checkpoint(
                forSession: sessionId, messageId: messageId
            ) else {
                self?.showToast("No file snapshot was kept for that turn")
                return
            }
            let plan = await SessionCheckpointStore.shared.plan(
                sessionId: sessionId, checkpointId: checkpoint.id
            )
            guard let self else { return }
            guard !plan.isEmpty else {
                self.showToast("Nothing to restore — those turns changed no files")
                return
            }
            self.pendingRestore = PendingRestore(
                checkpointId: checkpoint.id,
                messageId: messageId,
                label: checkpoint.label,
                plan: plan
            )
        }
    }

    public func cancelPendingRestore() {
        pendingRestore = nil
    }

    public func confirmPendingRestore() {
        guard let pending = pendingRestore, let sessionId = currentSessionId else { return }
        pendingRestore = nil
        Task { [weak self] in
            let outcome = await SessionCheckpointStore.shared.restore(
                sessionId: sessionId, checkpointId: pending.checkpointId
            )
            guard let self else { return }
            self.refreshRestorePoints()
            self.showToast(Self.describeRestore(outcome))
        }
    }

    /// Say what actually happened, including what could not be put back. A restore that quietly
    /// skipped a file would leave the user believing in a state their disk is not in.
    static func describeRestore(_ outcome: SessionCheckpointStore.RestoreOutcome) -> String {
        var parts: [String] = []
        let changed = outcome.restored.count + outcome.deleted.count
        parts.append("Restored \(changed) file(s) across \(outcome.turnsUndone) turn(s)")
        if !outcome.deleted.isEmpty {
            parts.append("\(outcome.deleted.count) created file(s) removed")
        }
        if !outcome.unrecoverable.isEmpty {
            parts.append("\(outcome.unrecoverable.count) could not be snapshotted and were left alone")
        }
        if !outcome.failed.isEmpty {
            parts.append("\(outcome.failed.count) failed to write")
        }
        return parts.joined(separator: " · ")
    }

    public func togglePinSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].isPinned.toggle()
            persistence.saveSessions(sessions)
        }
    }

    public func archiveSession(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].isArchived.toggle()
            persistence.saveSessions(sessions)
        }
    }

    public func renameSession(_ session: Session, newTitle: String) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].title = newTitle
            persistence.saveSessions(sessions)
        }
    }

    public enum SessionExportFormat {
        case markdown
        case json
        case html
    }

    public func exportCurrentSession(as format: SessionExportFormat) {
        guard let session = currentSession, !session.messages.isEmpty else {
            showToast("Session is empty")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)

        switch format {
        case .markdown:
            savePanel.nameFieldStringValue = "\(safeTitle).md"
            savePanel.allowedContentTypes = [.plainText]
        case .json:
            savePanel.nameFieldStringValue = "\(safeTitle).json"
            savePanel.allowedContentTypes = [.json]
        case .html:
            savePanel.nameFieldStringValue = "\(safeTitle).html"
            savePanel.allowedContentTypes = [.html]
        }

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                switch format {
                case .markdown:
                    var md = "# \(session.title)\n\n"
                    md += "*Exported from SwiftOpenWork on \(Date().formatted())*\n\n---\n\n"
                    for m in session.messages {
                        let sender = m.role == .user ? "**User**" : "**\(m.agentName ?? "Agent")** (\(m.modelId ?? "LLM"))"
                        md += "### \(sender) - \(m.timestamp.formatted())\n\n"
                        if let r = m.reasoning, !r.isEmpty {
                            md += "> 🧠 **Thinking / Reasoning:**\n> " + r.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
                        }
                        for notice in m.notices where !notice.isEmpty {
                            md += "> ℹ️ \(notice)\n\n"
                        }
                        for tc in m.toolCalls {
                            md += "> **tool** `\(tc.toolName)` (\(tc.status.rawValue))\n"
                            md += "> args: `\(tc.argumentsJson)`\n"
                            if let out = tc.resultOutput, !out.isEmpty {
                                let preview = out.count > 1200 ? String(out.prefix(1200)) + "…" : out
                                md += ">\n> ```\n> " + preview.replacingOccurrences(of: "\n", with: "\n> ") + "\n> ```\n"
                            }
                            md += "\n"
                        }
                        if !m.content.isEmpty {
                            md += "\(m.content)\n\n"
                        }
                        if let halt = m.haltText, !halt.isEmpty {
                            md += "**HALT** (\(m.haltReason ?? "stopped")): \(halt)\n\n"
                        }
                        md += "---\n\n"
                    }
                    try md.write(to: url, atomically: true, encoding: .utf8)

                case .json:
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(session)
                    try data.write(to: url)

                case .html:
                    var html = """
                    <!DOCTYPE html>
                    <html>
                    <head>
                    <meta charset="utf-8">
                    <title>\(session.title)</title>
                    <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #1e1e2e; background: #fafafa; }
                    .msg { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
                    .user { border-left: 4px solid #6366f1; }
                    .agent { border-left: 4px solid #10b981; }
                    .meta { font-size: 0.85em; color: #64748b; margin-bottom: 10px; font-weight: 600; }
                    .reasoning { background: #f8fafc; border-left: 3px solid #f59e0b; padding: 10px 14px; margin-bottom: 12px; font-size: 0.9em; color: #475569; font-style: italic; }
                    pre { background: #1e1e2e; color: #cdd6f4; padding: 12px; border-radius: 6px; overflow-x: auto; }
                    </style>
                    </head>
                    <body>
                    <h1>\(session.title)</h1>
                    <p style="color: #64748b; font-size: 0.9em;">Exported from SwiftOpenWork on \(Date().formatted())</p>
                    <hr style="border: 0; border-top: 1px solid #e2e8f0; margin: 20px 0;">
                    """
                    for m in session.messages {
                        let isUser = m.role == .user
                        let sender = isUser ? "User" : "\(m.agentName ?? "Agent") (\(m.modelId ?? "LLM"))"
                        let cssClass = isUser ? "user" : "agent"
                        html += "<div class=\"msg \(cssClass)\">"
                        html += "<div class=\"meta\">\(sender) • \(m.timestamp.formatted())</div>"
                        if let r = m.reasoning, !r.isEmpty {
                            html += "<div class=\"reasoning\"><strong>🧠 Reasoning:</strong><br>\(r.replacingOccurrences(of: "\n", with: "<br>"))</div>"
                        }
                        let safeContent = m.content
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: ">", with: "&gt;")
                            .replacingOccurrences(of: "\n", with: "<br>")
                        html += "<div>\(safeContent)</div>"
                        html += "</div>"
                    }
                    html += "</body></html>"
                    try html.write(to: url, atomically: true, encoding: .utf8)
                }
                showToast("Exported session successfully!")
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Chat & Execution
    /// Send a chat turn.
    ///
    /// `onFinished` reports whether the turn actually ran. It exists because callers that record
    /// an outcome cannot otherwise tell: this method returns immediately, and returns *early*
    /// when a turn is already generating. "Run now" on an automation used to write
    /// `lastStatus = "Completed"` on the line after calling this, so a run rejected by the
    /// `isGenerating` guard was filed as a success without a single token being generated.
    public func sendMessage(
        text: String,
        attachments: [MessageAttachment] = [],
        onFinished: ((Bool) -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinished?(false); return }

        // Queue a follow-up instead of dropping the message when a turn is already running.
        if isGenerating {
            queuedFollowUp = QueuedComposerMessage(text: trimmed, attachments: attachments)
            composerText = ""
            showToast("Queued — sends when this turn finishes")
            onFinished?(false)
            return
        }

        guard var session = currentSession else {
            createNewSession()
            sendMessage(text: text, attachments: attachments, onFinished: onFinished)
            return
        }

        // Handle slash commands
        if trimmed.hasPrefix("/") {
            if handleSlashCommand(trimmed) {
                composerText = ""
                onFinished?(false)
                return
            }
        }

        let enriched = ComposerContextMentions.enrich(
            text: trimmed,
            workspacePath: currentWorkspace.folderPath
        )
        let modelContent = enriched.modelText

        let userMsg = ChatMessage(
            sessionId: session.id,
            role: .user,
            content: modelContent,
            timestamp: Date(),
            attachments: attachments
        )

        session.messages.append(userMsg)
        
        // Auto rename session title on first message
        if session.messages.filter({ $0.role == .user }).count == 1 {
            session.title = String(trimmed.prefix(35))
        }

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        }
        persistence.saveSessions(sessions)

        composerText = ""

        // "Prefer local, never silently reach the network." A local provider that is switched off
        // used to fall through to the first *enabled* provider in array order, which on a typical
        // configuration is a cloud one sitting earlier in the list than the local engine — so a
        // turn the user believed was local was answered over the network, with nothing said.
        if let resolution = currentProviderResolution, resolution.mustRefuse,
           let reason = resolution.refusalMessage {
            let refusal = ChatMessage(
                sessionId: session.id,
                role: .assistant,
                content: reason,
                isError: true
            )
            session.messages.append(refusal)
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx] = session
            }
            persistence.saveSessions(sessions)
            onFinished?(false)
            flushQueuedFollowUp()
            return
        }

        isGenerating = true
        turnStartedAt = Date()

        let agent = currentAgent
        let provider = currentProvider
        let model = currentModel
        let workspace = currentWorkspace
        let allAgentsList = agents
        // "Reasoning" composer pill: off forces no reasoning for this turn regardless of the
        // agent's own setting; on guarantees some reasoning even if the agent defaults to off.
        let reasoningOverride: ReasoningEffort = isReasoningEnabled
            ? (agent.reasoningEffort == .off ? .medium : agent.reasoningEffort)
            : .off

        currentExecutionTask?.cancel()
        currentExecutionTask = Task { [weak self] in
            await AgentRunner.shared.run(
                session: session,
                agent: agent,
                provider: provider,
                model: model,
                workspace: workspace,
                allAgents: allAgentsList,
                reasoningOverride: reasoningOverride,
                onMessageUpdated: { [weak self] updatedMsg in
                    guard let self = self else { return }
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        if let mIdx = self.sessions[sIdx].messages.firstIndex(where: { $0.id == updatedMsg.id }) {
                            self.sessions[sIdx].messages[mIdx] = updatedMsg
                        } else {
                            self.sessions[sIdx].messages.append(updatedMsg)
                        }
                        // Every streamed chunk lands here. Saving each one rewrote all chat
                        // history tens of times a second; once a second is enough while it
                        // streams, and the finished message is always saved.
                        let now = Date()
                        if !updatedMsg.isStreaming || now.timeIntervalSince(self.lastStreamingSessionSave) >= 1 {
                            self.lastStreamingSessionSave = now
                            self.persistence.saveSessions(self.sessions)
                        }
                    }
                },
                onSubAgentTaskCreated: { [weak self] subTask in
                    guard let self = self else { return }
                    self.activeSubAgentTasks.append(subTask)
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        self.sessions[sIdx].activeSubAgentTasks.append(subTask)
                    }
                },
                onSubAgentTaskUpdated: { [weak self] subTask in
                    guard let self = self else { return }
                    if let idx = self.activeSubAgentTasks.firstIndex(where: { $0.id == subTask.id }) {
                        self.activeSubAgentTasks[idx] = subTask
                    }
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        if let tIdx = self.sessions[sIdx].activeSubAgentTasks.firstIndex(where: { $0.id == subTask.id }) {
                            self.sessions[sIdx].activeSubAgentTasks[tIdx] = subTask
                        }
                    }
                },
                onInterAgentMessage: { [weak self] msg in
                    guard let self = self else { return }
                    self.interAgentMessages.append(msg)
                    if let sIdx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        self.sessions[sIdx].interAgentMessages.append(msg)
                    }
                },
                onSessionTodosUpdated: { [weak self] todos in
                    guard let self = self else { return }
                    self.updateSessionTodos(todos, sessionId: session.id)
                }
            )

            // Seal the turn's baseline before anything can call beginTurn again. The in-memory
            // window still dies with the next turn; this is the copy that outlives a relaunch.
            await SessionCheckpointStore.sealCurrentTurn(
                sessionId: session.id, messageId: userMsg.id, label: trimmed
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGenerating = false
                self.currentExecutionTask = nil
                self.persistence.saveSessions(self.sessions)
                onFinished?(true)
                self.refreshLoadedMLXModels()
                self.announceTurnFinished()
                self.refreshRestorePoints()
                self.flushQueuedFollowUp()
            }
        }
    }


    public func updateSessionTodos(_ todos: [SessionTodoItem], sessionId: String? = nil) {
        let id = sessionId ?? currentSessionId
        guard let id, let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].todos = todos
        persistence.saveSessions(sessions)
    }

    public func clearQueuedFollowUp() {
        queuedFollowUp = nil
    }

    /// Stop deliberately keeps the queue, so the user needs an explicit way to release it.
    public func sendQueuedFollowUpNow() {
        flushQueuedFollowUp()
    }

    private func flushQueuedFollowUp() {
        guard let queued = queuedFollowUp else { return }
        queuedFollowUp = nil
        sendMessage(text: queued.text, attachments: queued.attachments)
    }

    public func cancelCurrentGeneration() {
        currentExecutionTask?.cancel()
        currentExecutionTask = nil
        isGenerating = false
        ToolApprovalManager.shared.rejectAllPending()
        UserChoiceManager.shared.cancelAll()
        // Keep any queued follow-up — auto-sending after Stop felt like Stop was ignored.
        if queuedFollowUp != nil {
            showToast("Stopped — queued message kept")
        } else {
            showToast("Generation cancelled")
        }
    }

    public func continueAfterHalt() {
        sendMessage(text: "Continue from where you stopped. Do not repeat completed work.")
    }

    /// Jump to a `file:line` from a build or test failure.
    ///
    /// This used to reveal the file in Finder and paste an `@file:line` mention into the composer,
    /// so the only way to look at the failing line was another app. It opens in the editor now; the
    /// editor's @ button is there for when you do want to ask the agent about it.
    public func revealDiagnostic(file: String, line: Int?) {
        openInEditor(path: file, line: line)
    }

    /// Open a workspace file in the editor, at a 1-based line when given.
    ///
    /// Shows it where the user already is: Artifacts & Files has its own editor; anywhere else the
    /// inspector opens on its Editor tab, widened when it is too narrow to read code in.
    public func openInEditor(path: String, line: Int? = nil, selecting selection: (column: Int, length: Int)? = nil) {
        do {
            try EditorWorkspace.shared.open(path: path, line: line, selecting: selection, workspaceRoot: currentWorkspace.folderPath)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        guard navigationDestination != .artifacts else { return }
        if navigationDestination != .chat && navigationDestination != .tools {
            navigationDestination = .chat
        }
        revealInspector(tab: .editor, minimumWidth: 560)
    }

    /// Show Find in Project in the editor, searching for the editor's selection when there is one.
    public func showProjectSearch() {
        if navigationDestination != .chat && navigationDestination != .tools {
            navigationDestination = .chat
        }
        revealInspector(tab: .editor, minimumWidth: 560)
        EditorWorkspace.shared.showProjectSearch(prefill: EditorWorkspace.shared.selectionForSearch)
    }

    /// Open the inspector on `tab`, asking for at least `minimumWidth`.
    public func revealInspector(tab: InspectorTab, minimumWidth: Double) {
        inspectorTab = tab
        isInspectorOpen = true
        if WindowLayoutStore.inspectorWidth < minimumWidth {
            inspectorWidthRequest = minimumWidth
        }
    }

    private func handleSlashCommand(_ command: String) -> Bool {
        let parts = command.split(separator: " ")
        guard let first = parts.first?.lowercased() else { return false }
        
        switch first {
        case "/clear":
            if var session = currentSession {
                session.messages.removeAll()
                session.activeSubAgentTasks.removeAll()
                session.interAgentMessages.removeAll()
                session.todos.removeAll()
                if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[idx] = session
                }
                interAgentMessages.removeAll()
                activeSubAgentTasks.removeAll()
                persistence.saveSessions(sessions)
                showToast("Session cleared")
            }
            return true

        case "/plan":
            settings.planModeEnabled.toggle()
            showToast(settings.planModeEnabled
                      ? "Plan mode on — writes blocked until exit_plan_mode"
                      : "Plan mode off")
            return true

        case "/agent":
            if parts.count > 1 {
                let query = parts.dropFirst().joined(separator: " ").lowercased()
                if let found = agents.first(where: { $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query) }) {
                    selectedAgentId = found.id
                    showToast("Switched agent to \(found.name)")
                    return true
                }
            }
            navigationDestination = .agents
            return true

        case "/model":
            if parts.count > 1 {
                let query = parts.dropFirst().joined(separator: " ").lowercased()
                for p in providers {
                    if let m = p.models.first(where: { $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }) {
                        selectedProviderId = p.id
                        selectedModelId = m.id
                        showToast("Model switched to \(m.name)")
                        return true
                    }
                }
            }
            navigationDestination = .providers
            return true

        case "/help":
            if var session = currentSession {
                let helpMsg = ChatMessage(
                    sessionId: session.id,
                    role: .assistant,
                    content: """
                    ### SwiftOpenWork Available Slash Commands:
                    - `/agent <name>` - Switch current active agent or open Agents hub
                    - `/model <name>` - Switch active model provider or open Providers catalog
                    - `/plan` - Toggle plan mode (read-only until exit_plan_mode)
                    - `/clear` - Clear messages in this session
                    - `/settings` - Jump to App Settings
                    - `/tools` - Inspect MCP & built-in tools
                    - `/memory` - Search or view long-term memory
                    - `/help` - Show this command reference

                    Tip: type `@` then a path to attach file/folder context to your prompt.
                    """,
                    agentName: "System Help",
                    agentAvatar: "questionmark.circle.fill",
                    agentColor: "#8B5CF6"
                )
                session.messages.append(helpMsg)
                if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[idx] = session
                }
                persistence.saveSessions(sessions)
            }
            return true

        case "/settings":
            navigationDestination = .settings
            return true

        case "/tools":
            navigationDestination = .tools
            return true

        case "/memory":
            navigationDestination = .memory
            return true

        default:
            return false
        }
    }

    public func ensurePipelineFoldersExist(for workspace: Workspace) {
        guard workspace.isPipelineStagingEnabled else { return }
        let root = URL(fileURLWithPath: workspace.folderPath)
        let inputURL = root.appendingPathComponent(workspace.inputFolderPath.isEmpty ? "input" : workspace.inputFolderPath)
        let outputURL = root.appendingPathComponent(workspace.outputFolderPath.isEmpty ? "output" : workspace.outputFolderPath)
        
        try? FileManager.default.createDirectory(at: inputURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    }

    public func ensureWorkspaceFolderExists(for workspace: Workspace) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: workspace.folderPath) {
            try? fm.createDirectory(atPath: workspace.folderPath, withIntermediateDirectories: true)
        }
        if workspace.isPipelineStagingEnabled {
            ensurePipelineFoldersExist(for: workspace)
        }
    }

    public func switchWorkspace(to workspaceId: String) {
        guard let target = workspaces.first(where: { $0.id == workspaceId }) else { return }
        self.activeWorkspaceId = target.id
        self.settings.defaultWorkspaceId = target.id
        self.persistence.saveSettings(self.settings)

        ensureWorkspaceFolderExists(for: target)

        // Automatically select the assigned agent if linked to this workspace
        if let assignedAgentId = target.assignedAgentId, agents.contains(where: { $0.id == assignedAgentId }) {
            self.selectedAgentId = assignedAgentId
        }

        // Switch to the most recent session for this workspace, or create one if none exist
        let activeWsSessions = sessions.filter { $0.workspaceId == target.id && !$0.isArchived }
        if let mostRecent = activeWsSessions.first {
            self.selectSession(mostRecent)
        } else {
            self.createNewSession(agentId: target.assignedAgentId ?? selectedAgentId)
        }

        showToast("Switched to '\(target.name)'")
    }

    /// Put text and optional attachments in the message box, after anything already typed.
    public func addToComposer(text: String, attachments: [MessageAttachment] = []) {
        if !text.isEmpty {
            composerText = composerText.isEmpty ? text : composerText + "\n\n" + text
        }
        composerAttachmentInbox.append(contentsOf: attachments)
    }

    public func showToast(_ message: String) {
        self.toastMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                guard let self, self.toastMessage == message else { return }
                self.toastMessage = nil
            }
        }
    }

    // MARK: - Providers & Models
    public func saveProvider(_ provider: ModelProvider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        persistence.saveProviders(providers)
    }

    /// Fill in cloud API keys for the provider settings screens, which show them.
    ///
    /// Keys are not loaded at launch (see `ProviderCredentials`), so a key field would read as empty
    /// until the key was used. Called when those screens appear; reads run off the main thread, and
    /// nothing is saved — the keys are already in the Keychain.
    public func loadProviderKeysForDisplay() {
        let missing = providers.filter { $0.type == .cloud && $0.apiKey.isEmpty }
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            for provider in missing {
                let filled = await ProviderCredentials.hydrated(provider)
                guard !filled.apiKey.isEmpty else { continue }
                await MainActor.run {
                    guard let self, let index = self.providers.firstIndex(where: { $0.id == provider.id }),
                          self.providers[index].apiKey.isEmpty else { return }
                    self.providers[index].apiKey = filled.apiKey
                }
            }
        }
    }

    public func deleteProvider(_ provider: ModelProvider) {
        ProviderCredentials.forget(provider.id)
        providers.removeAll(where: { $0.id == provider.id })
        persistence.saveProviders(providers)
    }

    // MARK: - MLX Local Runtime & Discovery

    /// Re-apply the GPU memory budget ratio to the models already in memory.
    ///
    /// Moving that slider changes every "Runs well" / "Memory may be tight" badge, because the
    /// verdict is measured against `physicalRAM * ratio`. The alternative — a full rescan per
    /// slider step — walks every attached model volume, so re-judge what is already loaded
    /// instead. A rescan produces the same verdicts; see `scanInstalledModels`.
    public func rejudgeLocalMLXCompatibility() {
        let ratio = settings.mlxGpuMemoryBudgetRatio
        localMLXModels = localMLXModels.map { $0.judged(atBudgetRatio: ratio) }
    }

    public func rescanMLXModels() {
        isScanningMLX = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let models = LocalMLXEngine.shared.scanInstalledModels(settings: PersistenceManager.shared.loadSettings())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.localMLXModels = models
                self.isScanningMLX = false

                // Synchronize discovered MLX models with the oMLX / vMLX providers
                let installed = models.filter { $0.isDownloaded }
                if !installed.isEmpty {
                    for i in 0..<self.providers.count {
                        if self.providers[i].kind == .omlx || self.providers[i].kind == .vmlx {
                            var updatedModels: [ModelInfo] = []
                            for m in installed {
                                let info = ModelInfo(
                                    id: m.id,
                                    name: "\(m.name) (\(m.quantization ?? "MLX"))",
                                    providerId: self.providers[i].id,
                                    contextWindow: m.contextWindow ?? 131072,
                                    supportsVision: m.isVLM,
                                    supportsReasoning: m.useCase == .reasoning,
                                    supportsStreaming: true,
                                    supportsTools: true,
                                    description: m.description,
                                    isDefault: m.isTopPick,
                                    speedTier: m.useCase == .fast ? "Fast" : "Powerful"
                                )
                                updatedModels.append(info)
                            }
                            if !updatedModels.isEmpty {
                                self.providers[i].models = updatedModels
                            }
                        }
                    }
                    self.persistence.saveProviders(self.providers)
                }
            }
        }
    }

    public func pullMLXModel(_ model: LocalMLXModel) {
        isPullingModel = true
        pullModelProgress = 0.0
        pullModelStatusText = "Downloading \(model.name) weights..."

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await LocalMLXEngine.shared.pullModel(repoId: model.id) { [weak self] fraction, status in
                    Task { @MainActor in
                        self?.pullModelProgress = fraction
                        self?.pullModelStatusText = "\(status)"
                    }
                }
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("MLX model '\(model.name)' installed successfully!")
                    self.rescanMLXModels()
                }
            } catch {
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func pullOllamaModel(name: String) {
        guard let ollama = providers.first(where: { $0.kind == .ollama }) else { return }
        isPullingModel = true
        pullModelProgress = 0.0
        pullModelStatusText = "Connecting to Ollama at \(ollama.baseUrl)..."
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await OllamaService.shared.pullModel(provider: ollama, modelName: name) { [weak self] fraction, status in
                    Task { @MainActor in
                        self?.pullModelProgress = fraction
                        self?.pullModelStatusText = "\(status): \(Int(fraction * 100))%"
                    }
                }
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("Model \(name) pulled successfully!")
                    self.refreshModels(for: ollama)
                }
            } catch {
                await MainActor.run {
                    self.isPullingModel = false
                    self.showToast("Failed to pull model: \(error.localizedDescription)")
                }
            }
        }
    }

    public func refreshModels(for provider: ModelProvider) {
        Task { [weak self] in
            do {
                let models = try await ProviderRouter.shared.client(for: provider).listModels(provider: provider)
                await MainActor.run {
                    guard let self else { return }
                    if let idx = self.providers.firstIndex(where: { $0.id == provider.id }) {
                        if !models.isEmpty {
                            self.providers[idx].models = models
                            self.persistence.saveProviders(self.providers)
                            self.showToast("Fetched \(models.count) models for \(provider.name)")
                        } else {
                            self.showToast("No models returned by \(provider.name) endpoint (\(provider.baseUrl))")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.showToast("Could not fetch models: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Agents
    public func saveAgent(_ agent: Agent) {
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[idx] = agent
        } else {
            agents.append(agent)
        }
        persistence.saveAgents(agents)
    }

    public func deleteAgent(_ agent: Agent) {
        agents.removeAll(where: { $0.id == agent.id })
        persistence.saveAgents(agents)
    }

    // MARK: - Skills
    public func saveSkill(_ skill: Skill) {
        if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[idx] = skill
        } else {
            skills.append(skill)
        }
        persistence.saveSkills(skills)
        showToast("Skill '\(skill.name)' saved")
    }

    public func deleteSkill(_ skill: Skill) {
        skills.removeAll(where: { $0.id == skill.id })
        persistence.saveSkills(skills)
        showToast("Skill deleted")
    }

    public func importSkillFromFile(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent
            let skill = Skill(
                name: name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized,
                description: "Imported from \(url.lastPathComponent)",
                category: "Imported",
                content: content,
                source: .fileImport,
                filePath: url.path
            )
            saveSkill(skill)
            showToast("Imported skill: \(skill.name)")
        } catch {
            showToast("Failed to read skill file: \(error.localizedDescription)")
        }
    }

    public func importSkillsFromFolder(url: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        var importedCount = 0
        for case let fileUrl as URL in enumerator {
            if fileUrl.lastPathComponent.lowercased() == "skill.md" || fileUrl.pathExtension.lowercased() == "md" {
                if let content = try? String(contentsOf: fileUrl, encoding: .utf8), content.contains("#") {
                    let parentFolder = fileUrl.deletingLastPathComponent().lastPathComponent
                    let skillName = parentFolder.isEmpty ? fileUrl.deletingPathExtension().lastPathComponent : parentFolder
                    let skill = Skill(
                        name: skillName.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized,
                        description: "Imported from \(fileUrl.path)",
                        category: "Folder Import",
                        content: content,
                        source: .fileImport,
                        filePath: fileUrl.path
                    )
                    saveSkill(skill)
                    importedCount += 1
                }
            }
        }
        showToast("Imported \(importedCount) skills from directory")
    }

    public func importSkillFromUrl(urlString: String, name: String? = nil) {
        guard let url = URL(string: urlString) else {
            showToast("Invalid URL")
            return
        }
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let content = String(data: data, encoding: .utf8) else {
                    await MainActor.run { self?.showToast("Failed to fetch skill from URL") }
                    return
                }
                let skillName = name?.isEmpty == false ? name! : url.lastPathComponent.replacingOccurrences(of: ".md", with: "").capitalized
                let skill = Skill(
                    name: skillName,
                    description: "Imported from \(urlString)",
                    category: "Web Import",
                    content: content,
                    source: .urlImport,
                    url: urlString
                )
                await MainActor.run {
                    self?.saveSkill(skill)
                    self?.showToast("Imported skill: \(skill.name)")
                }
            } catch {
                await MainActor.run {
                    self?.showToast("Fetch error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Extensions & Plugins
    public func savePlugin(_ plugin: AppExtensionPlugin) {
        if let idx = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[idx] = plugin
        } else {
            plugins.append(plugin)
        }
        persistence.savePlugins(plugins)
        showToast("Plugin '\(plugin.name)' saved")
    }

    public func deletePlugin(_ plugin: AppExtensionPlugin) {
        plugins.removeAll(where: { $0.id == plugin.id })
        persistence.savePlugins(plugins)
        showToast("Deleted plugin '\(plugin.name)'")
    }

    public func importPluginFromFile(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if let decoded = try? JSONDecoder().decode(AppExtensionPlugin.self, from: data) {
                savePlugin(decoded)
                showToast("Imported plugin: \(decoded.name)")
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = (json["name"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let desc = (json["description"] as? String) ?? "Imported from \(url.lastPathComponent)"
                let command = (json["command"] as? String) ?? ""
                let plugin = AppExtensionPlugin(
                    name: name,
                    description: desc,
                    pluginType: .customScript,
                    source: .file,
                    pathOrUrl: url.path,
                    command: command
                )
                savePlugin(plugin)
                showToast("Imported plugin config: \(plugin.name)")
            } else {
                let _ = String(data: data, encoding: .utf8) ?? ""
                let plugin = AppExtensionPlugin(
                    name: url.deletingPathExtension().lastPathComponent.capitalized,
                    description: "Script plugin loaded from \(url.lastPathComponent)",
                    pluginType: .customScript,
                    source: .file,
                    pathOrUrl: url.path,
                    command: url.path
                )
                savePlugin(plugin)
                showToast("Imported script plugin: \(plugin.name)")
            }
        } catch {
            showToast("Failed to read plugin: \(error.localizedDescription)")
        }
    }

    public func importPluginFromUrl(urlString: String, name: String? = nil) {
        guard let url = URL(string: urlString) else {
            showToast("Invalid URL")
            return
        }
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    await MainActor.run { self?.showToast("Failed to fetch from URL") }
                    return
                }
                let pluginName = name?.isEmpty == false ? name! : url.lastPathComponent.replacingOccurrences(of: ".json", with: "").capitalized
                if let decoded = try? JSONDecoder().decode(AppExtensionPlugin.self, from: data) {
                    await MainActor.run {
                        self?.savePlugin(decoded)
                        self?.showToast("Imported plugin: \(decoded.name)")
                    }
                } else {
                    let plugin = AppExtensionPlugin(
                        name: pluginName,
                        description: "Remote plugin loaded from \(urlString)",
                        pluginType: .mcpServer,
                        source: .gitUrl,
                        pathOrUrl: urlString
                    )
                    await MainActor.run {
                        self?.savePlugin(plugin)
                        self?.showToast("Imported plugin: \(plugin.name)")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.showToast("Plugin fetch error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - MCP Servers
    public func saveMcpServer(_ config: MCPServerConfig) {
        if let idx = settings.mcpServers.firstIndex(where: { $0.id == config.id }) {
            settings.mcpServers[idx] = config
        } else {
            settings.mcpServers.append(config)
        }
        updateSettings(settings)
        syncMcpTools()
        showToast("MCP Server '\(config.name)' saved")
    }

    public func deleteMcpServer(_ config: MCPServerConfig) {
        let toolId = "mcp_\(config.id)"
        let clean = config.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        let toolName = "\(clean)_call"

        settings.mcpServers.removeAll(where: { $0.id == config.id })
        updateSettings(settings)

        tools.removeAll(where: { $0.id == toolId || $0.name == toolName })
        persistence.saveTools(tools)

        showToast("MCP Server deleted")
    }

    public func syncMcpTools() {
        var currentTools = persistence.loadTools()

        for server in settings.mcpServers {
            let toolId = "mcp_\(server.id)"
            let clean = server.name.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            let toolName = "\(clean)_call"

            if let idx = currentTools.firstIndex(where: { $0.id == toolId || $0.name == toolName }) {
                currentTools[idx].displayName = "\(server.name) MCP Server"
                currentTools[idx].description = "Executes tools and actions via the \(server.name) MCP server (\(server.transportType.displayName))"
                currentTools[idx].category = .mcp
                currentTools[idx].isEnabled = server.isEnabled
            } else {
                currentTools.append(Tool(
                    id: toolId,
                    name: toolName,
                    displayName: "\(server.name) MCP Server",
                    description: "Executes tools and actions via the \(server.name) MCP server (\(server.transportType.displayName))",
                    category: .mcp,
                    isEnabled: server.isEnabled
                ))
            }
        }

        // Remove tools for MCP servers that no longer exist
        currentTools.removeAll { tool in
            if tool.category == .mcp && tool.id.hasPrefix("mcp_") && tool.id != "mcp_universal_call" {
                let serverId = String(tool.id.dropFirst(4))
                return !settings.mcpServers.contains(where: { $0.id == serverId })
            }
            return false
        }

        self.tools = currentTools
        persistence.saveTools(currentTools)
    }

    // MARK: - Workspaces
    public func saveWorkspace(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
        persistence.saveWorkspaces(workspaces)
        ensureWorkspaceFolderExists(for: workspace)
    }

    /// Create a workspace from the new-workspace sheet, and set up its folder when it is new or
    /// empty: starter files from `template` and a git repository, which session diffs, agent
    /// worktrees and `git_commit` all need. A folder that already has files is only registered.
    ///
    /// Code projects do not get the staged pipeline's `input/` and `output/` folders; they are
    /// for file-drop automations and were cluttering every repository.
    @discardableResult
    public func createWorkspace(
        name: String,
        category: WorkspaceCategory,
        assignedAgentId: String?,
        folderPath: String,
        template: WorkspaceBootstrap.StarterTemplate
    ) -> Workspace {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder: String
        if !folderPath.isEmpty {
            folder = (folderPath as NSString).expandingTildeInPath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let baseWs = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath)
            folder = (baseWs as NSString).appendingPathComponent(trimmedName.replacingOccurrences(of: " ", with: "-"))
        }
        let ws = Workspace(
            name: trimmedName,
            icon: category.icon,
            color: ["#8B5CF6", "#3B82F6", "#10B981", "#EC4899", "#F59E0B", "#06B6D4"].randomElement() ?? "#8B5CF6",
            folderPath: folder,
            category: category,
            assignedAgentId: category == .agent ? assignedAgentId.flatMap { $0.isEmpty ? nil : $0 } : nil,
            isPipelineStagingEnabled: category != .project && template == .empty,
            inputFolderPath: "input",
            outputFolderPath: "output"
        )
        saveWorkspace(ws)

        let staging: Set<String> = ws.isPipelineStagingEnabled ? [ws.inputFolderPath, ws.outputFolderPath] : []
        Task { [weak self] in
            let outcome = await WorkspaceBootstrap.bootstrap(
                folder: folder,
                template: template,
                projectName: trimmedName,
                ignoring: staging
            )
            // An existing project picked with no template is the common case; nothing to say.
            let quiet = template == .empty && outcome.writtenFiles.isEmpty && !outcome.initialisedRepository
            guard !quiet, !outcome.summary.isEmpty else { return }
            self?.showToast(outcome.summary)
        }
        return ws
    }

    /// Register a folder that already exists on disk as a workspace, or switch to the workspace
    /// already pointing at it.
    ///
    /// `createWorkspace` is the path for "make me a new project"; this is the path for "I already
    /// have one". The distinction that matters is the duplicate check: without it, opening the
    /// same checkout twice leaves two entries in the switcher with separate session histories,
    /// and the user has no way to tell which one they are in.
    @discardableResult
    public func openExistingProject(at url: URL) -> Workspace {
        let path = (url.path as NSString).standardizingPath
        if let existing = workspaces.first(where: {
            ($0.folderPath as NSString).standardizingPath == path
        }) {
            switchWorkspace(to: existing.id)
            showToast("Opened '\(existing.name)'")
            return existing
        }
        let ws = createWorkspace(
            name: url.lastPathComponent,
            category: .project,
            assignedAgentId: nil,
            folderPath: path,
            template: .empty
        )
        switchWorkspace(to: ws.id)
        showToast("Opened '\(ws.name)'")
        return ws
    }

    public func deleteWorkspace(_ workspace: Workspace) {
        workspaces.removeAll(where: { $0.id == workspace.id })
        if activeWorkspaceId == workspace.id {
            if let first = workspaces.first {
                switchWorkspace(to: first.id)
            } else {
                let defaultWs = Workspace.default
                workspaces.append(defaultWs)
                switchWorkspace(to: defaultWs.id)
            }
        }
        persistence.saveWorkspaces(workspaces)
        showToast("Deleted workspace '\(workspace.name)'")
    }

    public func duplicateWorkspace(_ workspace: Workspace) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseWs = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath)
        let cleanName = "\(workspace.name) (Copy)"
        let newFolderPath = (baseWs as NSString).appendingPathComponent(cleanName.replacingOccurrences(of: " ", with: "-"))
        
        let newWs = Workspace(
            name: cleanName,
            icon: workspace.icon,
            color: workspace.color,
            folderPath: newFolderPath,
            category: workspace.category,
            assignedAgentId: workspace.assignedAgentId,
            isPipelineStagingEnabled: workspace.isPipelineStagingEnabled,
            inputFolderPath: workspace.inputFolderPath,
            outputFolderPath: workspace.outputFolderPath
        )
        saveWorkspace(newWs)
        showToast("Duplicated '\(workspace.name)'")
    }

    public func generateWorkspacesForAgents() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseWs = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath)
        var createdCount = 0

        for agent in agents {
            if !workspaces.contains(where: { $0.assignedAgentId == agent.id }) {
                let sanitizedName = agent.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                let wsFolder = (baseWs as NSString).appendingPathComponent(sanitizedName)
                let newWs = Workspace(
                    name: "\(agent.name) Workspace",
                    icon: agent.avatar.isEmpty ? "person.crop.circle" : agent.avatar,
                    color: agent.color.isEmpty ? "#8B5CF6" : agent.color,
                    folderPath: wsFolder,
                    category: .agent,
                    assignedAgentId: agent.id,
                    isPipelineStagingEnabled: true,
                    inputFolderPath: "input",
                    outputFolderPath: "output"
                )
                saveWorkspace(newWs)
                createdCount += 1
            }
        }

        if createdCount > 0 {
            showToast("Created \(createdCount) dedicated agent workspaces!")
        } else {
            showToast("All agents already have dedicated workspaces.")
        }
    }

    // MARK: - Watch Folders & Watch Items
    public func saveWatchItem(_ item: WatchItem) {
        if let idx = watchItems.firstIndex(where: { $0.id == item.id }) {
            watchItems[idx] = item
        } else {
            watchItems.append(item)
        }
        persistence.saveWatchItems(watchItems)
        restartWatchEngine()
        showToast("Watch target '\(item.name)' saved")
    }

    public func deleteWatchItem(_ item: WatchItem) {
        watchItems.removeAll(where: { $0.id == item.id })
        persistence.saveWatchItems(watchItems)
        restartWatchEngine()
        showToast("Deleted watch target '\(item.name)'")
    }

    public func restartWatchEngine() {
        let activeItems = watchItems.filter { $0.isEnabled }
        WatchFolderEngine.shared.startWatching(items: activeItems) { [weak self] item, eventSummary in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleWatchEventTriggered(for: item, summary: eventSummary)
            }
        }
    }

    public func handleWatchEventTriggered(for item: WatchItem, summary: String) {
        if let idx = watchItems.firstIndex(where: { $0.id == item.id }) {
            var updated = watchItems[idx]
            updated.lastEventAt = Date()
            updated.lastEventSummary = summary
            updated.eventsCount += 1
            watchItems[idx] = updated
            persistence.saveWatchItems(watchItems)
        }

        showToast("⚡️ Watch event in '\(item.name)'")

        if item.autoGenerateArtifact {
            triggerWatchScan(item)
        }
    }

    public func triggerWatchScan(_ item: WatchItem) {
        let agent = agents.first(where: { $0.id == item.targetAgentId }) ?? currentAgent
        let provider = currentProvider
        let model = currentModel
        let ws = workspaces.first(where: { $0.id == item.workspaceId }) ?? currentWorkspace

        showToast("Generating \(item.artifactTemplate.displayName)...")

        Task { [weak self] in
            guard let self = self else { return }
            await WatchFolderEngine.shared.triggerManualScan(
                item: item,
                workspace: ws,
                agent: agent,
                provider: provider,
                model: model
            ) { [weak self] newArtifact in
                Task { @MainActor in
                    guard let self else { return }
                    self.saveArtifact(newArtifact)
                    if let idx = self.watchItems.firstIndex(where: { $0.id == item.id }) {
                        self.watchItems[idx].createdArtifactsCount += 1
                        self.persistence.saveWatchItems(self.watchItems)
                    }
                    self.showToast("🎉 Generated \(newArtifact.title)")
                }
            }
        }
    }

    // MARK: - Artifacts Management
    public func saveArtifact(_ artifact: AutomationArtifact) {
        if let idx = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[idx] = artifact
        } else {
            artifacts.insert(artifact, at: 0)
        }
        persistence.saveArtifacts(artifacts)
    }

    public func deleteArtifact(_ artifact: AutomationArtifact) {
        artifacts.removeAll(where: { $0.id == artifact.id })
        persistence.saveArtifacts(artifacts)
        showToast("Artifact deleted")
    }

    public func createArtifactFromAutomation(_ automation: Automation) {
        let agent = agents.first(where: { $0.id == automation.targetAgentId }) ?? currentAgent
        let provider = currentProvider
        let model = currentModel
        let ws = workspaces.first(where: { $0.id == automation.workspaceId }) ?? currentWorkspace

        showToast("Executing automation: \(automation.name)...")

        let prompt = """
        \(automation.promptTemplate)

        Please synthesize a structured executive artifact (such as a Morning Brief, Project Status Digest, or Report).
        Format in rich Markdown with clean sections, emojis, and clear takeaways.
        """

        Task { [weak self] in
            let autoAccumulator = SubAgentAccumulator()
            var failure: Error?
            do {
                try await ProviderRouter.shared.stream(
                    provider: provider,
                    model: model,
                    systemPrompt: agent.systemPrompt,
                    messages: [ChatMessage(sessionId: "auto-\(automation.id)", role: .user, content: prompt)],
                    temperature: agent.temperature,
                    maxTokens: 2048,
                    reasoningEffort: .off,
                    tools: []
                ) { chunk in
                    Task { @MainActor in
                        if !chunk.deltaText.isEmpty {
                            autoAccumulator.append(chunk.deltaText)
                        }
                    }
                }
            } catch {
                // The provider call failed. Filing a report that says the pipeline is "healthy"
                // would be a fabricated success — the artifact must say what actually happened.
                failure = error
            }

            let produced = autoAccumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = failure == nil && !produced.isEmpty
            let synthesized: String
            if succeeded {
                synthesized = autoAccumulator.text
            } else {
                let cause = failure?.localizedDescription ?? "the model returned nothing."
                synthesized = """
                # ⚠️ \(automation.name) did not run
                *Timestamp: \(Date().formatted())*

                \(automation.description)

                This automation failed: \(cause)

                No report was generated. Nothing below this line was produced by the agent.
                """
            }

            let artifact = AutomationArtifact(
                workspaceId: ws.id,
                automationId: automation.id,
                agentId: agent.id,
                agentName: agent.name,
                title: "\(automation.name) - \(Date().formatted(date: .abbreviated, time: .shortened))",
                subtitle: "Automated report from \(agent.name)",
                category: .report,
                content: synthesized,
                format: "markdown",
                sourceTrigger: "Automation: \(automation.name)"
            )

            await MainActor.run {
                guard let self else { return }
                self.saveArtifact(artifact)
                self.recordAutomationRun(
                    id: automation.id,
                    succeeded: succeeded,
                    summary: succeeded
                        ? "Generated artifact: \(artifact.title)"
                        : "Failed: \(failure?.localizedDescription ?? "the model returned nothing.")"
                )
                self.showToast(succeeded
                    ? "🎉 Generated Artifact for '\(automation.name)'"
                    : "⚠️ '\(automation.name)' failed — see the artifact for why")
            }
        }
    }

    /// Record the outcome of an automation run.
    ///
    /// One place, so a run started from the UI, a schedule or a Shortcut cannot disagree about what
    /// "success" means — and so a failure can never be filed as a success by a path that forgot.
    public func recordAutomationRun(id: String, succeeded: Bool, summary: String) {
        guard let idx = automations.firstIndex(where: { $0.id == id }) else { return }
        var updated = automations[idx]
        updated.lastRunAt = Date()
        updated.lastStatus = succeeded ? "success" : "failed"
        updated.lastResultSummary = summary
        automations[idx] = updated
        persistence.saveAutomations(automations)
    }

    /// Record that a run has started. Status is "running", not "success".
    ///
    /// Every trigger used to record `succeeded: true` with "Started by…" at the start, to claim
    /// `lastRunAt` so a crashing run cannot re-fire every tick. The claim is right; the status was
    /// not. A run that never finished — the app quit, the process was a test host that exited in
    /// a second — stayed "success" forever, and its session was a prompt with no reply. On this
    /// machine that was 25 sessions, each one filed as a success.
    public func recordAutomationRunStarted(id: String, summary: String, sessionId: String? = nil) {
        guard let idx = automations.firstIndex(where: { $0.id == id }) else { return }
        var updated = automations[idx]
        updated.lastRunAt = Date()
        updated.lastStatus = "running"
        updated.lastResultSummary = summary
        if let sessionId { updated.lastSessionId = sessionId }
        automations[idx] = updated
        persistence.saveAutomations(automations)
    }

    public func recordAutomationSession(id: String, sessionId: String) {
        guard let idx = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[idx].lastSessionId = sessionId
        persistence.saveAutomations(automations)
    }

    /// At launch nothing is running, so a run still marked "running" is one the app quit during.
    /// Say so on the card and on its session, instead of leaving a prompt with no reply that
    /// looks like a run which answered nothing.
    ///
    /// Launch only — `loadAll` is also called by Settings while a run may be in flight.
    func recoverInterruptedAutomationRuns() {
        let recovered = Self.recoveringInterruptedRuns(automations: automations, sessions: sessions)
        if recovered.automations != automations {
            automations = recovered.automations
            persistence.saveAutomations(automations)
        }
        if recovered.sessions != sessions {
            sessions = recovered.sessions
            persistence.saveSessions(sessions)
        }
    }

    /// Pure, so the rule is testable without the real data directory the test host runs on.
    nonisolated static func recoveringInterruptedRuns(
        automations: [Automation],
        sessions: [Session]
    ) -> (automations: [Automation], sessions: [Session]) {
        var automations = automations
        var sessions = sessions
        for index in automations.indices where automations[index].lastStatus == "running" {
            automations[index].lastStatus = "interrupted"
            automations[index].lastResultSummary = "Did not finish: the app quit while this run was in progress."
            if let sessionId = automations[index].lastSessionId,
               let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
               !sessions[sIdx].title.hasSuffix(interruptedTitleSuffix) {
                sessions[sIdx].title += interruptedTitleSuffix
            }
        }
        return (automations, sessions)
    }

    nonisolated static let interruptedTitleSuffix = " (interrupted)"

    /// Sound the end of a turn, if the user asked for it.
    ///
    /// The setting existed and nothing read it. Only when the app is in the background: a chime
    /// for something the user is already watching happen is noise, and the reason to want one is
    /// that a local model can take minutes.
    private func announceTurnFinished() {
        let duration = turnStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        turnStartedAt = nil

        guard settings.playNotificationSounds else { return }
        guard !NSApplication.shared.isActive else { return }
        NSSound(named: "Glass")?.play()

        // A chime says "something happened"; it cannot say which session, and it is gone the
        // moment it ends. The banner is what survives ten minutes away from the desk.
        let last = currentSession?.messages.last { $0.role == .assistant }
        if let notice = TurnCompletionNotifier.notice(
            enabled: settings.playNotificationSounds,
            appIsActive: NSApplication.shared.isActive,
            failed: last?.isError ?? false,
            duration: duration,
            sessionTitle: currentSession?.title ?? "",
            summary: last?.content
        ) {
            TurnCompletionNotifier.post(notice)
        }
    }

    // MARK: - Settings
    public func updateSettings(_ newSettings: AppSettings) {
        self.settings = newSettings
        persistence.saveSettings(newSettings)
        showToast("Settings saved")
    }
}

extension AppState: EngineHost {
    /// The preview sits beside chat and tools; anywhere else, opening it would move the user.
    public func revealPreviewIfWatched() {
        if navigationDestination != .chat && navigationDestination != .tools { return }
        revealInspector(tab: .preview, minimumWidth: 560)
    }
}

/// Calls `onChange` on the main actor whenever the MLX engine loads or unloads a model.
///
/// The engine posts from whatever thread it is on, so the handler hops to the main actor itself.
/// Selector-based, so NotificationCenter drops the registration when this object is freed and
/// `AppState.deinit` has no observer token to remove.
@MainActor
private final class MLXLoadedModelsObserver: NSObject {
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(loadedModelsDidChange), name: .mlxLoadedModelsDidChange, object: nil
        )
    }

    @objc nonisolated private func loadedModelsDidChange(_ note: Notification) {
        Task { @MainActor in self.onChange() }
    }
}
