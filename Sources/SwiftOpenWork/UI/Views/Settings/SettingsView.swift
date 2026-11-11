import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

public struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State var showingResetAlert = false
    @State var slashEditingId: String? = nil
    @State var slashCommandName = ""
    @State var slashDescription = ""
    @State var slashPrompt = ""
    @State var slashProblem: String? = nil
    @State var updateOutcome: UpdateChecker.Outcome? = nil
    @State var checkingForUpdates = false
    @State var newEnvKey = ""
    @State var newEnvVal = ""
    @State var showingAddSkill = false
    @State var selectedSkillForDetail: Skill? = nil
    @State var showingAddMcp = false
    @State var selectedMcpForEdit: MCPServerConfig? = nil
    @State var mcpStatusReports: [MCPServerReport] = []
    @State var mcpStatusBusy = false
    /// Server ids whose per-tool switches are expanded.
    @State var expandedMcpToolLists: Set<String> = []
    @State var showingAddPlugin = false
    @State var selectedPluginForDetail: AppExtensionPlugin? = nil
    @State var pluginSearchText = ""
    @State var selectedPluginTypeFilter: String = "all"
    @State var skillSearchText = ""
    /// Skills read from the active workspace's `.swiftopenwork/skills/` folder. Not persisted —
    /// the files are the state, so this is refreshed from disk rather than cached in settings.
    @State var projectSkills: [Skill] = []
    @State var showingCreateWorkspaceModal = false
    @State var showingEditWorkspaceModal = false
    @State var workspaceToEdit: Workspace? = nil
    @State var newWsName = ""
    @State var newWsCategory: WorkspaceCategory = .general
    @State var newWsAgentId = ""
    @State var newWsFolderPath = ""
    @State var newWsTemplate: WorkspaceBootstrap.StarterTemplate = .empty
    @State var showingAddWatchItemModal = false
    @State var editingWatchItem: WatchItem? = nil
    @State var googleClientId = ""
    @State var googleClientSecret = ""
    @State var googleApiKey = ""
    @State var googleAccessToken = ""
    @State var googleRefreshToken = ""
    /// The Google secrets have been read (in the background). Their fields stay disabled until then,
    /// so nothing typed is overwritten when the read finishes.
    @State var googleCredentialsLoaded = false
    @State var googleConnectionStatus = ""
    @State var isTestingGoogleConnection = false
    @State var isSigningInGoogle = false
    @State var showGoogleAdvancedCredentials = false
    @State var googleIsSignedIn = false
    @State var googleSignedInDisplay = ""
    // AI Providers page
    @State var addingProviderGroup: ProviderType? = nil
    @State var editingProvider: ModelProvider? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Settings Sidebar
            settingsSidebar
                .frame(width: 240)
                .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Right Settings Content & Top Header
            VStack(spacing: 0) {
                // Top Settings Header Bar
                settingsTopHeader

                Divider()
                    .background(ThemeColors.border(for: appState.settings.theme))

                // Main Scrollable Page
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch appState.settingsTab {
                        case "general":
                            generalPage
                        case "mlx":
                            mlxSettingsPage
                        case "preferences":
                            preferencesPage
                        case "permissions":
                            permissionsPage
                        case "watchFolders":
                            watchFoldersPage
                        case "extensions":
                            extensionsPage
                        case "advanced":
                            advancedPage
                        case "ai":
                            aiProvidersPage
                        case "appearance":
                            appearancePage
                        case "environment":
                            environmentPage
                        case "updates":
                            updatesPage
                        case "recovery":
                            recoveryPage
                        case "debug":
                            debugPage
                        case "skills":
                            skillsPage
                        case "memory":
                            memoryPage
                        case "slashCommands":
                            slashCommandsPage
                        default:
                            generalPage
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(ThemeColors.bg(for: appState.settings.theme))
        }
        .sheet(isPresented: $showingCreateWorkspaceModal) {
            createWorkspaceModal
        }
        .sheet(item: $workspaceToEdit) { ws in
            EditWorkspaceModalView(appState: appState, workspace: ws, isPresented: Binding(
                get: { workspaceToEdit != nil },
                set: { if !$0 { workspaceToEdit = nil } }
            ))
        }
        .sheet(isPresented: $showingAddPlugin) {
            AddExtensionModalView(appState: appState, isPresented: $showingAddPlugin)
        }
        .sheet(item: $selectedPluginForDetail) { plug in
            ExtensionDetailModalView(appState: appState, isPresented: Binding(
                get: { selectedPluginForDetail != nil },
                set: { if !$0 { selectedPluginForDetail = nil } }
            ), plugin: plug)
        }
        .sheet(isPresented: $showingAddWatchItemModal) {
            WatchItemEditModalView(appState: appState, isPresented: $showingAddWatchItemModal)
        }
        .sheet(item: $editingWatchItem) { item in
            WatchItemEditModalView(appState: appState, isPresented: Binding(
                get: { editingWatchItem != nil },
                set: { if !$0 { editingWatchItem = nil } }
            ), watchItem: item)
        }
    }

    var createWorkspaceModal: some View {
        VStack(spacing: 16) {
            Text("Add New Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Name")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("e.g. External SSD Drive, AI Research, SwiftOpenWork", text: $newWsName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Category")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: $newWsCategory) {
                        ForEach(WorkspaceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                WorkspaceTemplatePicker(template: $newWsTemplate)

                if newWsCategory == .agent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned Agent Sandbox")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $newWsAgentId) {
                            Text("None (Shared Workspace)").tag("")
                            ForEach(appState.agents) { ag in
                                Text("\(ag.name) (\(ag.role))").tag(ag.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Directory Path (External SSD, Custom Folder, or Existing Project)")
                        .font(.system(size: 11, weight: .semibold))
                    
                    HStack(spacing: 6) {
                        TextField(
                            "e.g. /Volumes/MyExternalSSD/Workspaces or /Volumes/Storage/Projects/MyRepo",
                            text: Binding(
                                get: {
                                    if newWsFolderPath.isEmpty && !newWsName.isEmpty {
                                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                                        let baseWs = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath)
                                        return (baseWs as NSString).appendingPathComponent(newWsName.replacingOccurrences(of: " ", with: "-"))
                                    }
                                    return newWsFolderPath
                                },
                                set: { newWsFolderPath = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.canCreateDirectories = true
                            panel.prompt = "Choose Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                newWsFolderPath = url.path
                                if newWsName.isEmpty {
                                    newWsName = url.lastPathComponent
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    showingCreateWorkspaceModal = false
                    newWsName = ""
                    newWsAgentId = ""
                    newWsFolderPath = ""
                    newWsTemplate = .empty
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Workspace") {
                    guard !newWsName.isEmpty else { return }
                    let ws = appState.createWorkspace(
                        name: newWsName,
                        category: newWsCategory,
                        assignedAgentId: newWsAgentId,
                        folderPath: newWsFolderPath,
                        template: newWsTemplate
                    )
                    appState.switchWorkspace(to: ws.id)
                    showingCreateWorkspaceModal = false
                    newWsName = ""
                    newWsAgentId = ""
                    newWsFolderPath = ""
                    newWsTemplate = .empty
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Left Settings Sidebar
    var settingsSidebar: some View {
        VStack(spacing: 0) {
            // Header with Back Button
            HStack(spacing: 8) {
                Button {
                    appState.navigationDestination = .chat
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Back")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Settings")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Grouped Tab Items
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // WORKSPACE GROUP
                    sidebarGroup(title: "WORKSPACE") {
                        sidebarItem(id: "mlx", title: "Apple Silicon MLX", icon: "cpu.fill")
                        sidebarItem(id: "preferences", title: "Preferences", icon: "slider.horizontal.3")
                        sidebarItem(id: "permissions", title: "Permissions & Folders", icon: "folder.badge.gearshape")
                        sidebarItem(id: "watchFolders", title: "Watch Folders & Triggers", icon: "eye.circle.fill")
                        sidebarItem(id: "extensions", title: "Extensions & Plugins", icon: "puzzlepiece.extension")
                        sidebarItem(id: "advanced", title: "Advanced", icon: "wrench.and.screwdriver")
                    }

                    // GLOBAL GROUP
                    sidebarGroup(title: "GLOBAL") {
                        sidebarItem(id: "general", title: "General", icon: "gearshape")
                        sidebarItem(id: "ai", title: "AI Providers", icon: "bolt.fill")
                        sidebarItem(id: "appearance", title: "Appearance", icon: "paintbrush")
                        sidebarItem(id: "environment", title: "Environment Variables", icon: "terminal")
                        sidebarItem(id: "updates", title: "Updates", icon: "arrow.triangle.2.circlepath")
                        sidebarItem(id: "recovery", title: "Backup & Recovery", icon: "shield.checkered")
                        sidebarItem(id: "debug", title: "Debug & Logs", icon: "ant")
                    }

                    sidebarGroup(title: "SKILLS & MEMORY") {
                        sidebarItem(id: "skills", title: "Skills & MCP", icon: "sparkles")
                        sidebarItem(id: "memory", title: "Memory", icon: "brain")
                        sidebarItem(id: "slashCommands", title: "Slash Commands", icon: "slash.circle")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
    }

    func sidebarGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            content()
        }
    }

    func sidebarItem(id: String, title: String, icon: String) -> some View {
        let isSelected = appState.settingsTab == id
        return Button {
            appState.settingsTab = id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
            .cornerRadius(6)
            // See SideInspectorView: a transparent background leaves only the glyphs clickable,
            // so every row except the selected one has a hit target the size of its text.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top Settings Header Bar
    var settingsTopHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tabTitle(for: appState.settingsTab))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                Text(tabDescription(for: appState.settingsTab))
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            // Workspace Badge
            HStack(spacing: 5) {
                Circle().fill(Color(hex: appState.currentWorkspace.color)).frame(width: 8, height: 8)
                Text(appState.currentWorkspace.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .cornerRadius(6)

            // Close Settings Button
            Button {
                appState.navigationDestination = .chat
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .frame(width: 26, height: 26)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .clipShape(Circle())
            }
            .buttonStyle(.hitTestable)
            .help("Close Settings (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }


    // MARK: - Shared helpers
    /// Push the new-agent defaults onto every existing agent.
    ///
    /// Without this the settings above are reachable only by creating a new agent, which is a
    /// strange thing to have to do to change the temperature of the one you already use.
    func applyAgentDefaultsToAllAgents() {
        let temperature = appState.settings.defaultTemperature
        let maxTokens = appState.settings.defaultMaxTokens
        let effort = appState.settings.defaultReasoningEffort
        for index in appState.agents.indices {
            appState.agents[index].temperature = temperature
            appState.agents[index].maxTokens = maxTokens
            appState.agents[index].reasoningEffort = effort
        }
        PersistenceManager.shared.saveAgents(appState.agents)
        let count = appState.agents.count
        appState.showToast("Applied to \(count) agent\(count == 1 ? "" : "s")")
    }

    func tabTitle(for tab: String) -> String {
        switch tab {
        case "general": return "General Settings"
        case "mlx": return "Apple Silicon MLX Engine"
        case "preferences": return "Preferences"
        case "permissions": return "Permissions & Authorized Folders"
        case "watchFolders": return "Watch Folders & Ingestion Triggers"
        case "extensions": return "Extensions & Plugins"
        case "advanced": return "Advanced Multi-Agent Settings"
        case "ai": return "AI Model Providers"
        case "appearance": return "Appearance & Styling"
        case "environment": return "Environment Variables"
        case "updates": return "Updates & Diagnostics"
        case "recovery": return "Backup & Recovery"
        case "debug": return "Debug & Developer Logs"
        case "skills": return "Skills & MCP"
        case "memory": return "Long-Term Memory"
        case "slashCommands": return "Slash Commands"
        default: return "Settings"
        }
    }

    func tabDescription(for tab: String) -> String {
        switch tab {
        case "general": return "Core application defaults and workspace directory"
        case "mlx": return "Manage on-device MLX model discovery, Hugging Face caches, LM Studio weights, and GPU memory budgets"
        case "preferences": return "Model sampling, reasoning effort, and chat behavior"
        case "permissions": return "Authorized folders, terminal execution policies, and security"
        case "watchFolders": return "Directory listeners, file debouncing, and automated Morning Brief artifact synthesis"
        case "extensions": return "Install, manage, configure, or remove custom plugins and MCP extensions"
        case "advanced": return "Sub-agent orchestration depth and collaboration room"
        case "ai": return "Configure local Ollama, LM Studio, and cloud API endpoints"
        case "appearance": return "Themes, accent colors, font sizes, and window transparency"
        case "environment": return "Key-value environment variables passed to tools"
        case "updates": return "Application version and release update checking"
        case "recovery": return "Export data archives or perform factory reset"
        case "debug": return "Internal state telemetry and live inspector logs"
        case "skills": return "Model Context Protocol tools and custom extensions"
        case "memory": return "Persistent knowledge stored across agent sessions"
        case "slashCommands": return "Built-in commands, and your own that send a saved prompt"
        default: return "Configure SwiftOpenWork preferences"
        }
    }
}
