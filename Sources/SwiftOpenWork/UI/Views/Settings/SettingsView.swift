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
    @State private var showingResetAlert = false
    @State private var updateOutcome: UpdateChecker.Outcome? = nil
    @State private var checkingForUpdates = false
    @State private var newEnvKey = ""
    @State private var newEnvVal = ""
    @State private var showingAddSkill = false
    @State private var selectedSkillForDetail: Skill? = nil
    @State private var showingAddMcp = false
    @State private var selectedMcpForEdit: MCPServerConfig? = nil
    @State private var mcpStatusReports: [MCPServerReport] = []
    @State private var mcpStatusBusy = false
    /// Server ids whose per-tool switches are expanded.
    @State private var expandedMcpToolLists: Set<String> = []
    @State private var showingAddPlugin = false
    @State private var selectedPluginForDetail: AppExtensionPlugin? = nil
    @State private var pluginSearchText = ""
    @State private var selectedPluginTypeFilter: String = "all"
    @State private var skillSearchText = ""
    /// Skills read from the active workspace's `.swiftopenwork/skills/` folder. Not persisted —
    /// the files are the state, so this is refreshed from disk rather than cached in settings.
    @State private var projectSkills: [Skill] = []
    @State private var showingCreateWorkspaceModal = false
    @State private var showingEditWorkspaceModal = false
    @State private var workspaceToEdit: Workspace? = nil
    @State private var newWsName = ""
    @State private var newWsCategory: WorkspaceCategory = .general
    @State private var newWsAgentId = ""
    @State private var newWsFolderPath = ""
    @State private var newWsTemplate: WorkspaceBootstrap.StarterTemplate = .empty
    @State private var showingAddWatchItemModal = false
    @State private var editingWatchItem: WatchItem? = nil
    @State private var googleClientId = ""
    @State private var googleClientSecret = ""
    @State private var googleApiKey = ""
    @State private var googleAccessToken = ""
    @State private var googleRefreshToken = ""
    /// The Google secrets have been read (in the background). Their fields stay disabled until then,
    /// so nothing typed is overwritten when the read finishes.
    @State private var googleCredentialsLoaded = false
    @State private var googleConnectionStatus = ""
    @State private var isTestingGoogleConnection = false
    @State private var isSigningInGoogle = false
    @State private var showGoogleAdvancedCredentials = false
    @State private var googleIsSignedIn = false
    @State private var googleSignedInDisplay = ""

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

    private var createWorkspaceModal: some View {
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
    private var settingsSidebar: some View {
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
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
    }

    private func sidebarGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            content()
        }
    }

    private func sidebarItem(id: String, title: String, icon: String) -> some View {
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
    private var settingsTopHeader: some View {
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

    // MARK: - Pages
    // 1. General
    private var generalPage: some View {
        VStack(spacing: 18) {
            // Active Workspace Switcher & Configuration
            SettingsCard(title: "Active Workspace", description: "Currently operating in \(appState.currentWorkspace.name)", icon: "folder.fill") {
                // Workspace Switcher Dropdown
                SettingsRow(title: "Active Workspace", subtitle: "Select active workspace for all chat, tools, terminal and storage operations", icon: "arrow.triangle.2.circlepath") {
                    Picker("", selection: Binding(
                        get: { appState.activeWorkspaceId },
                        set: { newId in
                            appState.switchWorkspace(to: newId)
                        }
                    )) {
                        ForEach(appState.workspaces) { ws in
                            HStack {
                                Text(ws.name)
                                if ws.category == .agent {
                                    Text("🤖 (Agent)")
                                } else if ws.category == .research {
                                    Text("🔬 (Research)")
                                }
                            }
                            .tag(ws.id)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Workspace Name", subtitle: "Display label for this workspace", icon: "pencil") {
                    TextField("Workspace Name", text: Binding(
                        get: { appState.currentWorkspace.name },
                        set: { val in
                            var ws = appState.currentWorkspace
                            ws.name = val
                            appState.saveWorkspace(ws)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                }

                SettingsRow(title: "Workspace Category", subtitle: "Determines role, isolation level, and icon representation", icon: "tag.fill") {
                    Picker("", selection: Binding(
                        get: { appState.currentWorkspace.category },
                        set: { newCat in
                            var ws = appState.currentWorkspace
                            ws.category = newCat
                            ws.icon = newCat.icon
                            appState.saveWorkspace(ws)
                        }
                    )) {
                        ForEach(WorkspaceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Assigned Agent Sandbox", subtitle: "Bind this workspace to a dedicated AI Agent role", icon: "person.crop.circle.badge.checkmark") {
                    Picker("", selection: Binding(
                        get: { appState.currentWorkspace.assignedAgentId ?? "" },
                        set: { newAgentId in
                            var ws = appState.currentWorkspace
                            ws.assignedAgentId = newAgentId.isEmpty ? nil : newAgentId
                            appState.saveWorkspace(ws)
                        }
                    )) {
                        Text("None (Shared Workspace)").tag("")
                        ForEach(appState.agents) { ag in
                            Text("\(ag.name) (\(ag.role))").tag(ag.id)
                        }
                    }
                    .frame(width: 240)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingsRow(title: "Workspace Path", subtitle: "Root folder for code, file tools, terminal execution, and artifacts", icon: "folder") {
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") {
                                let url = URL(fileURLWithPath: appState.currentWorkspace.folderPath)
                                appState.ensureWorkspaceFolderExists(for: appState.currentWorkspace)
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Browse Folder / Drive...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.prompt = "Select Workspace Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    var ws = appState.currentWorkspace
                                    ws.folderPath = url.path
                                    appState.saveWorkspace(ws)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    // Direct text editable path field with quick action buttons
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                        TextField("Path (e.g. /Volumes/ExternalSSD/Workspaces/MyProject)", text: Binding(
                            get: { appState.currentWorkspace.folderPath },
                            set: { val in
                                var ws = appState.currentWorkspace
                                ws.folderPath = val
                                appState.saveWorkspace(ws)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                        Button("Set to External SSD...") {
                            let panel = NSOpenPanel()
                            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.canCreateDirectories = true
                            panel.prompt = "Select External Volume Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                var ws = appState.currentWorkspace
                                ws.folderPath = url.path
                                appState.saveWorkspace(ws)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.leading, 26)
                }

                SettingsRow(title: "Automated Pipeline Staging", subtitle: "Enable automated 'input/' & 'output/' staging directory processing", icon: "tray.2.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.currentWorkspace.isPipelineStagingEnabled },
                        set: { val in
                            var ws = appState.currentWorkspace
                            ws.isPipelineStagingEnabled = val
                            appState.saveWorkspace(ws)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                // Workspace Actions Row
                HStack(spacing: 10) {
                    Button {
                        showingCreateWorkspaceModal = true
                    } label: {
                        Label("Add New Workspace", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.duplicateWorkspace(appState.currentWorkspace)
                    } label: {
                        Label("Duplicate Workspace", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.generateWorkspacesForAgents()
                    } label: {
                        Label("Auto-Generate Workspaces for All Agents", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    if appState.currentWorkspace.id != "default-workspace" {
                        Button(role: .destructive) {
                            appState.deleteWorkspace(appState.currentWorkspace)
                        } label: {
                            Label("Delete Workspace", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }

            // Workspaces Overview List
            SettingsCard(title: "All Configured Workspaces (\(appState.workspaces.count))", description: "Manage dedicated agent environments and project workspaces", icon: "square.grid.2x2.fill") {
                VStack(spacing: 8) {
                    ForEach(appState.workspaces) { ws in
                        let isSelected = ws.id == appState.activeWorkspaceId
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: ws.color))
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(ws.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                    Text(ws.category.displayName)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12))
                                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                        .cornerRadius(4)

                                    if isSelected {
                                        Text("ACTIVE")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(3)
                                    }
                                }

                                Text(ws.folderPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                    .lineLimit(1)
                            }

                            Spacer()

                            if let agentId = ws.assignedAgentId, let ag = appState.agents.first(where: { $0.id == agentId }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 10))
                                    Text(ag.name)
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.4))
                                .cornerRadius(4)
                            }

                            HStack(spacing: 6) {
                                Button("Edit / Path") {
                                    workspaceToEdit = ws
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                if !isSelected {
                                    Button("Switch") {
                                        appState.switchWorkspace(to: ws.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                }
                            }
                        }
                        .padding(10)
                        .background(isSelected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.08) : ThemeColors.border(for: appState.settings.theme).opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : Color.clear, lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                }
            }

            SettingsCard(title: "Default Lead Agent & Model", description: "Default selections for new sessions", icon: "person.crop.circle.badge.checkmark") {
                SettingsRow(title: "Default Agent", subtitle: "Initial agent assigned to new chats", icon: "person.fill") {
                    Picker("", selection: $appState.settings.defaultAgentId) {
                        ForEach(appState.agents) { ag in
                            Text(ag.name).tag(ag.id)
                        }
                    }
                    .frame(width: 220)
                }

                SettingsRow(title: "Default Model Provider", subtitle: "Provider for default inference", icon: "server.rack") {
                    Picker("", selection: Binding(
                        get: { appState.settings.defaultProviderId },
                        set: { newProvId in
                            appState.settings.defaultProviderId = newProvId
                            if let prov = appState.providers.first(where: { $0.id == newProvId }) {
                                if !prov.models.contains(where: { $0.id == appState.settings.defaultModelId }) {
                                    appState.settings.defaultModelId = prov.models.first?.id ?? ""
                                }
                            }
                            appState.updateSettings(appState.settings)
                        }
                    )) {
                        ForEach(appState.providers.filter { $0.isEnabled }) { prov in
                            Text(prov.name).tag(prov.id)
                        }
                    }
                    .frame(width: 220)
                }

                // Default Model Picker
                let currentProv = appState.providers.first(where: { $0.id == appState.settings.defaultProviderId }) ?? appState.providers.first
                SettingsRow(title: "Default Model", subtitle: "Primary model used for new sessions (\(currentProv?.name ?? "Provider"))", icon: "cpu") {
                    Picker("", selection: $appState.settings.defaultModelId) {
                        if let prov = currentProv {
                            ForEach(prov.models) { model in
                                Text("\(model.name) (\(model.speedTier))").tag(model.id)
                            }
                        }
                    }
                    .frame(width: 220)
                }
            }

            SettingsCard(title: "Startup & Persistence", description: "Storage cadence and launch behavior", icon: "clock.fill") {
                SettingsRow(
                    title: "Launch at Login",
                    subtitle: LaunchAtLogin.statusDescription(),
                    icon: "power"
                ) {
                    // Bound to what macOS reports, not to the stored Bool: registration can be
                    // refused or left pending approval, and the switch must show what is true.
                    Toggle("", isOn: Binding(
                        get: { LaunchAtLogin.isEnabled },
                        set: { wanted in
                            switch LaunchAtLogin.set(wanted) {
                            case .success(let actual):
                                appState.settings.startOnLogin = actual
                                appState.updateSettings(appState.settings)
                                if actual != wanted {
                                    appState.showToast(LaunchAtLogin.statusDescription())
                                }
                            case .failure(let error):
                                appState.showToast("Could not change login item: \(error.localizedDescription)")
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // MLX Settings Page (Parity with Osaurus & GrizzyClaw)
    private var mlxSettingsPage: some View {
        VStack(spacing: 16) {
            // Hardware Status Card
            SettingsCard(
                title: "Apple Silicon Unified Memory",
                description: "Hardware telemetry and runtime budget for MLX metal shaders",
                icon: "cpu.fill"
            ) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Physical RAM")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f GB", LocalMLXEngine.physicalRAMGB))
                            .font(.system(size: 16, weight: .bold))
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Safe GPU Memory Budget")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f GB (%.0f%%)", LocalMLXEngine.physicalRAMGB * appState.settings.mlxGpuMemoryBudgetRatio, appState.settings.mlxGpuMemoryBudgetRatio * 100))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                    }
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed MLX Models")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("\(appState.localMLXModels.filter { $0.isDownloaded }.count) Active")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                SettingsRow(title: "GPU Memory Budget Ratio", subtitle: "Caps MLX's buffer cache and decides which models are marked as fitting", icon: "gauge.with.dots.needle.bottom.50percent") {
                    HStack(spacing: 8) {
                        // Re-judge on commit, not per step: the badges below depend on this ratio,
                        // and a rescan per 0.05 increment walks every attached model volume.
                        Slider(
                            value: $appState.settings.mlxGpuMemoryBudgetRatio,
                            in: 0.5...0.9,
                            step: 0.05,
                            onEditingChanged: { editing in
                                if !editing { appState.rejudgeLocalMLXCompatibility() }
                            }
                        )
                            .frame(width: 140)
                        Text("\(Int(appState.settings.mlxGpuMemoryBudgetRatio * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

            }

            // External Model Discovery Locations (Osaurus Parity)
            SettingsCard(
                title: "External Model Locations & Hub Caches",
                description: "Scan existing model weights on this Mac without copying or duplicating files",
                icon: "externaldrive.badge.person.crop"
            ) {
                SettingsRow(title: "Hugging Face Cache (~/.cache/huggingface)", subtitle: "Reference downloaded Hugging Face snapshots in-place", icon: "folder.badge.gearshape") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.scanHuggingFaceCache },
                        set: { val in
                            appState.settings.scanHuggingFaceCache = val
                            appState.updateSettings(appState.settings)
                            appState.rescanMLXModels()
                        }
                    ))
                    .toggleStyle(.switch)
                }

                if appState.settings.scanHuggingFaceCache {
                    SettingsRow(title: "Custom HF Cache Path", subtitle: "Optional custom HF_HOME or HF_HUB_CACHE folder", icon: "folder") {
                        HStack(spacing: 6) {
                            TextField("~/.cache/huggingface/hub", text: $appState.settings.customHFCachePath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    appState.settings.customHFCachePath = url.path
                                    appState.updateSettings(appState.settings)
                                    appState.rescanMLXModels()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                SettingsRow(
                    title: "Preload Model at Launch",
                    subtitle: "Load your default in-process MLX model on startup, so the first message does not wait for it",
                    icon: "bolt.horizontal.circle"
                ) {
                    // The setting was stored but had no control and no reader, so it could never
                    // be turned on and would have done nothing if it had been.
                    Toggle("", isOn: Binding(
                        get: { appState.settings.autoLoadTopMLXModelOnLaunch },
                        set: { val in
                            appState.settings.autoLoadTopMLXModelOnLaunch = val
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "LM Studio Library (~/.cache/lm-studio)", subtitle: "Discover safetensors and MLX weights from LM Studio", icon: "desktopcomputer") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.scanLMStudioModels },
                        set: { val in
                            appState.settings.scanLMStudioModels = val
                            appState.updateSettings(appState.settings)
                            appState.rescanMLXModels()
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Custom MLX Models Directory", subtitle: "Specific folder on external SSD or hard drive", icon: "externaldrive.fill") {
                    HStack(spacing: 6) {
                        TextField("e.g. /Volumes/YourDrive/Models — leave empty to sweep mounted volumes", text: $appState.settings.customMLXModelsDirectory)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.settings.customMLXModelsDirectory = url.path
                                appState.updateSettings(appState.settings)
                                appState.rescanMLXModels()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    if appState.isScanningMLX {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        Text("Scanning local directories...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(appState.localMLXModels.filter { $0.isDownloaded }.count) local models discovered")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        appState.rescanMLXModels()
                    } label: {
                        Label("Rescan Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isScanningMLX)
                }
                .padding(.top, 4)
            }

            // Discovered & Curated MLX Models List
            SettingsCard(
                title: "MLX Model Catalog & Installed Weights (\(appState.localMLXModels.count))",
                description: "Select, run, or download Apple Silicon optimized model weights",
                icon: "square.grid.2x2.fill"
            ) {
                VStack(spacing: 8) {
                    ForEach(appState.localMLXModels) { model in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: model.useCase.iconName)
                                .font(.system(size: 14))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(model.name)
                                        .font(.system(size: 12, weight: .bold))

                                    if let q = model.quantization {
                                        Text(q)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)
                                    }

                                    if model.isDownloaded {
                                        Text("INSTALLED")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(3)
                                    }

                                    Text(model.compatibility.displayName)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(model.compatibility == .runsWell ? .green : (model.compatibility == .tight ? .orange : .red))
                                }

                                Text(model.description)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(model.formattedRAM)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)

                            if model.isDownloaded {
                                Button("Select Model") {
                                    if let omlx = appState.providers.first(where: { $0.kind == .omlx }) {
                                        appState.selectedProviderId = omlx.id
                                        appState.selectedModelId = model.id
                                        appState.showToast("Selected \(model.name) as active model")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button("Download (\(model.formattedSize))") {
                                    appState.pullMLXModel(model)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    // 2. Preferences
    private var preferencesPage: some View {
        VStack(spacing: 16) {
            // Two cards, because these two groups behave differently and used to sit together
            // under one heading that described only the second. Temperature, Max Tokens and
            // Reasoning Effort are per-agent fields; a turn reads `agent.temperature`, so these
            // seed *new* agents and never touch an existing one. Top-P and the penalties below
            // are read live from settings on every request. A user dragging Temperature to 0.1
            // for "precise coding" was changing nothing about the agent actually answering.
            SettingsCard(title: "Defaults for New Agents", description: "Seeds the agent editor. Existing agents keep their own values — change those in AI Agents.", icon: "person.badge.plus") {
                SettingsRow(title: "Temperature (\(String(format: "%.2f", appState.settings.defaultTemperature)))", subtitle: "Lower for precise coding, higher for creative research", icon: "thermometer.medium") {
                    Slider(value: $appState.settings.defaultTemperature, in: 0.0...1.0, step: 0.05)
                        .frame(width: 180)
                }

                SettingsRow(title: "Max Output Tokens (\(appState.settings.defaultMaxTokens))", subtitle: "Completion token ceiling a new agent starts with", icon: "number") {
                    Stepper("", value: $appState.settings.defaultMaxTokens, in: 1024...32768, step: 1024)
                }

                SettingsRow(title: "Reasoning Effort", subtitle: "Budget for thinking models (Claude 3.7, DeepSeek R1, o1/o3)", icon: "brain") {
                    Picker("", selection: $appState.settings.defaultReasoningEffort) {
                        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    .frame(width: 200)
                }

                HStack {
                    Spacer()
                    Button("Apply to All Existing Agents") {
                        applyAgentDefaultsToAllAgents()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            SettingsCard(title: "Sampling", description: "Read live on every request, for every agent and provider", icon: "slider.horizontal.3") {
                SettingsRow(title: "Top-P Sampling (\(String(format: "%.2f", appState.settings.defaultTopP)))", subtitle: "Nucleus sampling probability threshold", icon: "chart.bar.xaxis") {
                    Slider(value: $appState.settings.defaultTopP, in: 0.1...1.0, step: 0.05)
                        .frame(width: 180)
                }
            }

            SettingsCard(title: "Repetition, Presence & Loop Control", description: "Fine-tune penalties and loop prevention across any LLM provider", icon: "repeat.circle.fill") {
                SettingsRow(title: "Frequency Penalty (\(String(format: "%.2f", appState.settings.defaultFrequencyPenalty)))", subtitle: "Penalizes repeated tokens based on cumulative frequency (-2.0 to 2.0)", icon: "waveform.path.ecg") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.defaultFrequencyPenalty, in: 0.0...1.0, step: 0.05)
                            .frame(width: 140)
                        Button("0.35") {
                            appState.settings.defaultFrequencyPenalty = 0.35
                            appState.updateSettings(appState.settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                SettingsRow(title: "Presence Penalty (\(String(format: "%.2f", appState.settings.defaultPresencePenalty)))", subtitle: "Penalizes repeated tokens based on presence in generated text (-2.0 to 2.0)", icon: "sparkle") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.defaultPresencePenalty, in: 0.0...1.0, step: 0.05)
                            .frame(width: 140)
                        Button("0.35") {
                            appState.settings.defaultPresencePenalty = 0.35
                            appState.updateSettings(appState.settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                SettingsRow(title: "Repeat Penalty (\(String(format: "%.2f", appState.settings.defaultRepeatPenalty)))", subtitle: "Multiplicative penalty used by Ollama and local engines (1.0 to 2.0)", icon: "arrow.triangle.2.circlepath") {
                    HStack(spacing: 8) {
                        Slider(value: $appState.settings.defaultRepeatPenalty, in: 1.0...2.0, step: 0.05)
                            .frame(width: 140)
                        Button("1.25") {
                            appState.settings.defaultRepeatPenalty = 1.25
                            appState.updateSettings(appState.settings)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                SettingsRow(title: "Auto-Detect & Optimize for Local Models", subtitle: "Automatically apply higher penalties and ReAct safety for MLX, Ollama, and local endpoints", icon: "wand.and.stars") {
                    Toggle("", isOn: $appState.settings.autoAdjustPenaltiesForLocalModels)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Autonomous Stream Loop Breaker", subtitle: "Halt autoregressive sentence looping in real-time using fuzzy similarity", icon: "shield.lefthalf.filled") {
                    Toggle("", isOn: $appState.settings.autoLoopBreakerEnabled)
                        .toggleStyle(.switch)
                }

                // Quick Diagnosis & Auto-Tuning presets
                HStack(spacing: 10) {
                    Button {
                        // Preset for local MLX / Ollama models (prone to repetition)
                        appState.settings.defaultFrequencyPenalty = 0.35
                        appState.settings.defaultPresencePenalty = 0.35
                        appState.settings.defaultRepeatPenalty = 1.25
                        appState.settings.autoAdjustPenaltiesForLocalModels = true
                        appState.settings.autoLoopBreakerEnabled = true
                        appState.updateSettings(appState.settings)
                        appState.showToast("Applied Optimized Anti-Looping Preset")
                    } label: {
                        Label("Apply Anti-Looping Preset (Recommended for MLX/Ollama)", systemImage: "bolt.badge.checkmark.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        // Preset for cloud models (OpenAI/Anthropic/DeepSeek)
                        appState.settings.defaultFrequencyPenalty = 0.0
                        appState.settings.defaultPresencePenalty = 0.0
                        appState.settings.defaultRepeatPenalty = 1.0
                        appState.settings.autoAdjustPenaltiesForLocalModels = true
                        appState.settings.autoLoopBreakerEnabled = true
                        appState.updateSettings(appState.settings)
                        appState.showToast("Applied Standard Cloud Model Defaults")
                    } label: {
                        Label("Reset to Standard Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }

            SettingsCard(title: "Chat Experience", description: "Streaming and context management", icon: "bubble.left.and.bubble.right") {
                SettingsRow(title: "Auto-Compact Context", subtitle: "Summarize old messages when nearing context limit", icon: "arrow.triangle.merge") {
                    Toggle("", isOn: $appState.settings.autoCompactContext)
                        .toggleStyle(.switch)
                }

                // `AgentRunner` has always read this; it had no control anywhere, so the only way
                // to change the threshold was to hand-edit settings.json.
                if appState.settings.autoCompactContext {
                    SettingsRow(title: "Compaction Threshold (\(appState.settings.contextCompactionThresholdTokens / 1000)k tokens)", subtitle: "Transcript size that triggers a summarize pass", icon: "arrow.down.right.and.arrow.up.left") {
                        Stepper("", value: $appState.settings.contextCompactionThresholdTokens, in: 8000...256_000, step: 4000)
                    }
                }

                SettingsRow(title: "Audio Notifications", subtitle: "Play chime when agents finish long tasks", icon: "speaker.wave.2") {
                    Toggle("", isOn: $appState.settings.playNotificationSounds)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 3. Permissions
    private var permissionsPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Terminal & Shell Configuration", description: "Default shell binary, execution environment, and interactive console", icon: "terminal.fill") {
                SettingsRow(title: "Default Terminal Shell", subtitle: "Shell executable for terminal tools and interactive console", icon: "chevron.left.forwardslash.chevron.right") {
                    Picker("", selection: Binding(
                        get: { appState.settings.terminalShell },
                        set: { newShell in
                            appState.settings.terminalShell = newShell
                            appState.updateSettings(appState.settings)
                            WorkspaceTerminalSession.shared.activeShellName = (newShell as NSString).lastPathComponent
                        }
                    )) {
                        Text("Zsh (/bin/zsh) [macOS Default]").tag("/bin/zsh")
                        Text("Bash (/bin/bash)").tag("/bin/bash")
                        Text("POSIX sh (/bin/sh)").tag("/bin/sh")
                        Text("Fish (/opt/homebrew/bin/fish)").tag("/opt/homebrew/bin/fish")
                        Text("Dash (/bin/dash)").tag("/bin/dash")
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Custom Shell Binary Path", subtitle: "Override with any custom shell or virtual environment binary", icon: "terminal") {
                    TextField("/bin/zsh", text: Binding(
                        get: { appState.settings.terminalShell },
                        set: { newPath in
                            appState.settings.terminalShell = newPath
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 240)
                }

                SettingsRow(title: "Safety Level", subtitle: "Permission policy for autonomous agent shell commands", icon: "shield") {
                    Picker("", selection: $appState.settings.terminalSafetyLevel) {
                        ForEach(TerminalSafetyLevel.allCases) { lvl in
                            Text(lvl.displayName).tag(lvl)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsRow(title: "Web Search Access", subtitle: "Allow agents to query web search APIs", icon: "globe") {
                    Toggle("", isOn: $appState.settings.allowWebAccess)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Ask Before Fetching New Sites", subtitle: "Approve each new site per chat, and every fetch from this Mac or local network. Off lets automations fetch unattended", icon: "hand.raised") {
                    Toggle("", isOn: $appState.settings.askBeforeFetchingNewSites)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Sandbox Agent File System", subtitle: "Restrict write operations strictly to workspace directory", icon: "lock.shield") {
                    Toggle("", isOn: $appState.settings.sandboxAgentFileSystem)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard(title: "Authorized Workspace Directories", description: "Paths agents are granted access to read and write", icon: "folder.fill") {
                ForEach(appState.settings.authorizedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text(folder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Spacer()
                        Button {
                            appState.settings.authorizedFolders.removeAll(where: { $0 == folder })
                            appState.updateSettings(appState.settings)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.hitTestable)
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.3))
                    .cornerRadius(6)
                }

                Button("Add Authorized Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        if !appState.settings.authorizedFolders.contains(url.path) {
                            appState.settings.authorizedFolders.append(url.path)
                            appState.updateSettings(appState.settings)
                        }
                    }
                }
            }
        }
    }

    // 3b. Watch Folders & Real-Time Triggers
    private var watchFoldersPage: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Watch Folders & Ingestion Targets (\(appState.watchItems.count))",
                description: "Monitor directories and files to automatically synthesize Morning Briefs, Daily Updates, and Code Reviews",
                icon: "eye.circle.fill"
            ) {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Watch Target Monitors")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                            Text("Automatic background filesystem listeners trigger agent synthesis when files are modified or dropped in")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button {
                            showingAddWatchItemModal = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                Text("Add Watch Target...")
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if appState.watchItems.isEmpty {
                        Text("No watch targets configured. Click 'Add Watch Target' above to start monitoring directories.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(appState.watchItems) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.watchType.icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                        .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.name)
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                            Text(item.artifactTemplate.displayName)
                                                .font(.system(size: 9.5, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(ThemeColors.border(for: appState.settings.theme))
                                                .cornerRadius(4)
                                        }

                                        Text(item.path.isEmpty ? appState.currentWorkspace.folderPath : item.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    HStack(spacing: 8) {
                                        Button("Scan Now") {
                                            appState.triggerWatchScan(item)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("Edit") {
                                            editingWatchItem = item
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Toggle("", isOn: Binding(
                                            get: { item.isEnabled },
                                            set: { val in
                                                var updated = item
                                                updated.isEnabled = val
                                                appState.saveWatchItem(updated)
                                            }
                                        ))
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                    }
                                }
                                .padding(10)
                                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.25))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }

            SettingsCard(
                title: "Artifact Generation Defaults",
                description: "Executive brief formatting and automated pipeline output settings",
                icon: "sparkles.tv.fill"
            ) {
                SettingsRow(
                    title: "Default Briefing Agent",
                    subtitle: "Primary agent assigned to synthesize morning briefs and activity reports",
                    icon: "person.crop.circle.badge.checkmark"
                ) {
                    Picker("", selection: $appState.settings.defaultAgentId) {
                        ForEach(appState.agents) { ag in
                            Text("\(ag.name) (\(ag.role))").tag(ag.id)
                        }
                    }
                    .frame(width: 220)
                }

                SettingsRow(
                    title: "Interactive Live Canvas Output",
                    subtitle: "Render synthesized HTML, Tailwind, and React artifacts in the Live Canvas",
                    icon: "sparkles"
                ) {
                    Toggle("", isOn: .constant(true))
                        .toggleStyle(.switch)
                        .disabled(true)
                }
            }
        }
    }

    // 4. Extensions & Plugins Page
    private var extensionsPage: some View {
        VStack(spacing: 16) {
            googleIntegrationsCard

            // MARK: - TOP BAR & ACTIONS
            SettingsCard(
                title: "Extensions & Plugins Hub (\(appState.plugins.count))",
                description: "Install, manage, configure, or remove custom plugins, MCP tools, external scripts, and agent extensions",
                icon: "puzzlepiece.extension.fill"
            ) {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        // Search bar
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                            TextField("Filter extensions & plugins...", text: $pluginSearchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                            if !pluginSearchText.isEmpty {
                                Button {
                                    pluginSearchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))

                        // Type Filter
                        Picker("", selection: $selectedPluginTypeFilter) {
                            Text("All Types").tag("all")
                            Text("MCP Servers").tag("mcp")
                            Text("Custom Scripts").tag("script")
                            Text("Media & OCR").tag("media")
                            Text("Voice & Audio").tag("voice")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)

                        Spacer()

                        // Add Plugin Button
                        Button {
                            showingAddPlugin = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                Text("Add Extension / Plugin...")
                            }
                            .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // Quick Import Bar (File, Directory, URL)
                    HStack(spacing: 8) {
                        Button {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            panel.canChooseFiles = true
                            panel.allowedContentTypes = [
                                .json,
                                .shellScript,
                                UTType(filenameExtension: "sh") ?? .plainText,
                                UTType(filenameExtension: "py") ?? .plainText,
                                UTType(filenameExtension: "js") ?? .plainText
                            ]
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importPluginFromFile(url: url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.badge.plus")
                                Text("Import Manifest / Script File...")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                let plugin = AppExtensionPlugin(
                                    name: url.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized,
                                    description: "Folder plugin at \(url.path)",
                                    pluginType: .customScript,
                                    source: .directory,
                                    pathOrUrl: url.path,
                                    command: url.path
                                )
                                appState.savePlugin(plugin)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.plus")
                                Text("Load Plugin Directory...")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }
                }
            }

            // MARK: - INSTALLED PLUGINS LIST
            let filteredPlugins = appState.plugins.filter { plug in
                let matchesSearch = pluginSearchText.isEmpty ||
                    plug.name.localizedCaseInsensitiveContains(pluginSearchText) ||
                    plug.description.localizedCaseInsensitiveContains(pluginSearchText) ||
                    plug.command.localizedCaseInsensitiveContains(pluginSearchText)
                let matchesType = selectedPluginTypeFilter == "all" || plug.pluginType.rawValue == selectedPluginTypeFilter
                return matchesSearch && matchesType
            }

            SettingsCard(
                title: "Installed Extensions & Plugins (\(filteredPlugins.count))",
                description: "Active system plugins available across all agent sessions and autonomous loops",
                icon: "cube.box.fill"
            ) {
                if filteredPlugins.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        Text(appState.plugins.isEmpty ? "No extensions or plugins installed yet." : "No plugins match your filter criteria.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("Install from Catalog...") {
                            showingAddPlugin = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredPlugins) { plugin in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: plugin.pluginType.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 28, height: 28)
                                    .background(ThemeColors.border(for: appState.settings.theme))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(plugin.name)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                        Text(plugin.pluginType.displayName)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        Text(plugin.source.displayName)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.secondary.opacity(0.12))
                                            .cornerRadius(4)

                                        Text("v\(plugin.version)")
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                    }

                                    if !plugin.description.isEmpty {
                                        Text(plugin.description)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    if !plugin.command.isEmpty {
                                        Text(plugin.command)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button("Configure") {
                                        selectedPluginForDetail = plugin
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { plugin.isEnabled },
                                        set: { val in
                                            var updated = plugin
                                            updated.isEnabled = val
                                            appState.savePlugin(updated)
                                            if plugin.id == "plugin-gmail" {
                                                appState.settings.gmailExtensionEnabled = val
                                                appState.updateSettings(appState.settings)
                                                syncGoogleTools(names: ["gmail_list", "gmail_search"], enabled: val)
                                            } else if plugin.id == "plugin-google-calendar" {
                                                appState.settings.googleCalendarExtensionEnabled = val
                                                appState.updateSettings(appState.settings)
                                                syncGoogleTools(names: ["google_calendar_list", "google_calendar_upcoming"], enabled: val)
                                            }
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deletePlugin(plugin)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.85))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.hitTestable)
                                    .help("Remove Extension / Plugin")
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // MARK: - NATIVE HARDWARE EXTENSIONS
            SettingsCard(title: "Built-In Hardware & System Extensions", description: "Hardware-accelerated capabilities on Apple Silicon", icon: "cpu.fill") {
                SettingsRow(title: "Voice Input (Whisper / Speech Recognition)", subtitle: "Dictate prompts using microphone input", icon: "mic.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.voiceInputEnabled },
                        set: { val in
                            appState.settings.voiceInputEnabled = val
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Speech Synthesis", subtitle: "Read assistant replies aloud using macOS native TTS", icon: "speaker.wave.2.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.voiceSynthesisEnabled },
                        set: { val in
                            appState.settings.voiceSynthesisEnabled = val
                            appState.updateSettings(appState.settings)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                // `speechVoiceIdentifier` was stored, defaulted to Alex, and had no control
                // anywhere — the one setting with neither a reader nor a way to set it.
                if appState.settings.voiceSynthesisEnabled {
                    SettingsRow(title: "Voice", subtitle: "Installed macOS voice used for spoken replies", icon: "waveform") {
                        HStack(spacing: 8) {
                            Picker("", selection: Binding(
                                // An identifier naming a voice this Mac does not have must show
                                // as the system default, not as an empty control. Normalised on
                                // read rather than migrated, because resolving a voice means
                                // touching AVFoundation and `loadSettings` runs per turn.
                                get: { VoiceSpeechEngine.resolvedVoiceIdentifier(appState.settings.speechVoiceIdentifier) },
                                set: { val in
                                    appState.settings.speechVoiceIdentifier = val
                                    appState.updateSettings(appState.settings)
                                }
                            )) {
                                Text("System Default").tag("")
                                ForEach(VoiceSpeechEngine.installedVoices(), id: \.identifier) { voice in
                                    Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                                }
                            }
                            .frame(width: 220)

                            Button("Preview") {
                                VoiceSpeechEngine.shared.speak(text: "This is the SwiftOpenWork speaking voice.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                SettingsRow(title: "Generative Media & MLX Vision", subtitle: "Enable DALL-E, local Stable Diffusion, and Apple Vision tools", icon: "paintpalette.fill") {
                    Toggle("", isOn: Binding(
                        // Read the tools, not the stored Bool. This toggle writes through to the
                        // `.mediaVision` category, so enabling one of those tools from the Tools
                        // page left the switch reading "off" while the tools were on. A switch
                        // that reports the opposite of the truth is worse than one that does
                        // nothing.
                        get: {
                            let media = appState.tools.filter { $0.category == .mediaVision }
                            guard !media.isEmpty else { return appState.settings.imageGenerationEnabled }
                            return media.contains { $0.isEnabled }
                        },
                        set: { val in
                            appState.settings.imageGenerationEnabled = val
                            appState.updateSettings(appState.settings)
                            for idx in appState.tools.indices {
                                if appState.tools[idx].category == .mediaVision {
                                    appState.tools[idx].isEnabled = val
                                }
                            }
                            PersistenceManager.shared.saveTools(appState.tools)
                            appState.showToast(val ? "Enabled Vision & Media Tools" : "Disabled Vision & Media Tools")
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // 5. Advanced
    private var googleIntegrationsCard: some View {
        SettingsCard(
            title: "Google Integrations",
            description: "Sign in with Google to connect Gmail and Calendar. Client ID / secrets stay in the macOS Keychain.",
            icon: "envelope.badge.shield.half.filled"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if googleIsSignedIn {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(googleSignedInDisplay.isEmpty ? "Signed in to Google" : googleSignedInDisplay)
                                .font(.system(size: 12, weight: .semibold))
                            Text("Access tokens refresh automatically when they expire.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(8)
                }

                SecureField("Google OAuth Client ID", text: $googleClientId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!googleCredentialsLoaded)
                    .font(.system(size: 12))
                    .onChange(of: googleClientId) { _, newValue in
                        GoogleIntegrationsService.shared.clientId = newValue
                    }

                SecureField("Google OAuth Client Secret", text: $googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!googleCredentialsLoaded)
                    .font(.system(size: 12))
                    .onChange(of: googleClientSecret) { _, newValue in
                        GoogleIntegrationsService.shared.clientSecret = newValue
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Authorized redirect URI (required)")
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(GoogleIntegrationsService.authorizedRedirectURI)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ThemeColors.sidebarBg(for: appState.settings.theme))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                            )
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                GoogleIntegrationsService.authorizedRedirectURI,
                                forType: .string
                            )
                            googleConnectionStatus = "Copied redirect URI. Paste it into Google Cloud Console → Credentials → your OAuth client → Authorized redirect URIs."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("In Google Cloud Console, open your OAuth client and add that URI exactly (including the trailing slash). Prefer client type “Desktop app”; if you use “Web application”, this URI is required to avoid redirect_uri_mismatch.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isSigningInGoogle = true
                            googleConnectionStatus = ""
                            do {
                                googleConnectionStatus = try await GoogleIntegrationsService.shared.signInWithGoogle()
                                googleAccessToken = GoogleIntegrationsService.shared.accessToken
                                googleRefreshToken = GoogleIntegrationsService.shared.refreshToken
                                if !GoogleIntegrationsService.shared.signedInEmail.isEmpty {
                                    appState.settings.googleAccountEmail = GoogleIntegrationsService.shared.signedInEmail
                                    appState.updateSettings(appState.settings)
                                }
                                refreshGoogleSignedInState()
                            } catch is CancellationError {
                                googleConnectionStatus = "Sign-in cancelled."
                            } catch {
                                googleConnectionStatus = "Sign-in failed: \(error.localizedDescription)"
                            }
                            isSigningInGoogle = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSigningInGoogle {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                            }
                            Text(isSigningInGoogle ? "Waiting for browser…" : "Sign in with Google")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSigningInGoogle || !googleCredentialsLoaded || googleClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if googleIsSignedIn {
                        Button("Sign Out") {
                            GoogleIntegrationsService.shared.signOut()
                            googleAccessToken = ""
                            googleRefreshToken = ""
                            googleConnectionStatus = "Signed out of Google."
                            refreshGoogleSignedInState()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isSigningInGoogle)
                    }

                    Button {
                        Task {
                            isTestingGoogleConnection = true
                            googleConnectionStatus = await GoogleIntegrationsService.shared.testConnection()
                            isTestingGoogleConnection = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingGoogleConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isTestingGoogleConnection ? "Testing…" : "Test Connection")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTestingGoogleConnection || isSigningInGoogle)
                }

                if !googleConnectionStatus.isEmpty {
                    Text(googleConnectionStatus)
                        .font(.system(size: 11))
                        .foregroundColor(googleConnectionStatus.hasPrefix("✅") ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Advanced credentials", isExpanded: $showGoogleAdvancedCredentials) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Google account email (optional)", text: Binding(
                            get: { appState.settings.googleAccountEmail },
                            set: { val in
                                appState.settings.googleAccountEmail = val
                                appState.updateSettings(appState.settings)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                        SecureField("Google API Key (optional)", text: $googleApiKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!googleCredentialsLoaded)
                            .font(.system(size: 12))
                            .onChange(of: googleApiKey) { _, newValue in
                                GoogleIntegrationsService.shared.apiKey = newValue
                            }

                        SecureField("Manual OAuth Access Token", text: $googleAccessToken)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!googleCredentialsLoaded)
                            .font(.system(size: 12))
                            .onChange(of: googleAccessToken) { _, newValue in
                                GoogleIntegrationsService.shared.accessToken = newValue
                            }

                        SecureField("Manual OAuth Refresh Token", text: $googleRefreshToken)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!googleCredentialsLoaded)
                            .font(.system(size: 12))
                            .onChange(of: googleRefreshToken) { _, newValue in
                                GoogleIntegrationsService.shared.refreshToken = newValue
                            }

                        Text("Prefer Sign in with Google. Manual tokens are only for debugging.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 11.5))

                Divider()

                SettingsRow(title: "Enable Gmail", subtitle: "Allow agents to list and search Gmail", icon: "envelope.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.gmailExtensionEnabled },
                        set: { val in
                            appState.settings.gmailExtensionEnabled = val
                            appState.updateSettings(appState.settings)
                            syncGooglePlugin(id: "plugin-gmail", enabled: val)
                            syncGoogleTools(names: ["gmail_list", "gmail_search"], enabled: val)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Enable Google Calendar", subtitle: "Allow agents to list upcoming Google Calendar events", icon: "calendar") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.googleCalendarExtensionEnabled },
                        set: { val in
                            appState.settings.googleCalendarExtensionEnabled = val
                            appState.updateSettings(appState.settings)
                            syncGooglePlugin(id: "plugin-google-calendar", enabled: val)
                            syncGoogleTools(names: ["google_calendar_list", "google_calendar_upcoming"], enabled: val)
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
            .task {
                // Off the main thread: a Keychain read can wait on an authorisation prompt.
                let loaded = await GoogleIntegrationsService.shared.loadCredentials()
                googleClientId = loaded.clientId
                googleClientSecret = loaded.clientSecret
                googleApiKey = loaded.apiKey
                googleAccessToken = loaded.accessToken
                googleRefreshToken = loaded.refreshToken
                googleCredentialsLoaded = true
                refreshGoogleSignedInState()
            }
        }
    }

    private func refreshGoogleSignedInState() {
        let google = GoogleIntegrationsService.shared
        googleIsSignedIn = google.isSignedIn
        if !google.signedInName.isEmpty, !google.signedInEmail.isEmpty {
            googleSignedInDisplay = "Signed in as \(google.signedInName) <\(google.signedInEmail)>"
        } else if !google.signedInEmail.isEmpty {
            googleSignedInDisplay = "Signed in as \(google.signedInEmail)"
        } else if !appState.settings.googleAccountEmail.isEmpty, google.isSignedIn {
            googleSignedInDisplay = "Signed in as \(appState.settings.googleAccountEmail)"
        } else if google.isSignedIn {
            googleSignedInDisplay = "Signed in to Google"
        } else {
            googleSignedInDisplay = ""
        }
    }

    private func syncGooglePlugin(id: String, enabled: Bool) {
        if let plugin = appState.plugins.first(where: { $0.id == id }) {
            var updated = plugin
            updated.isEnabled = enabled
            appState.savePlugin(updated)
        } else {
            let name = id == "plugin-gmail" ? "Gmail" : "Google Calendar"
            let description = id == "plugin-gmail"
                ? "Read and search Gmail via Google APIs."
                : "List upcoming Google Calendar events."
            let permissions = id == "plugin-gmail"
                ? ["network:outbound", "google:gmail.readonly"]
                : ["network:outbound", "google:calendar.readonly"]
            appState.savePlugin(AppExtensionPlugin(
                id: id,
                name: name,
                description: description,
                pluginType: .workspaceTool,
                source: .builtIn,
                isEnabled: enabled,
                permissions: permissions
            ))
        }
    }

    private func syncGoogleTools(names: [String], enabled: Bool) {
        var tools = appState.tools
        var changed = false
        for name in names {
            if let idx = tools.firstIndex(where: { $0.name == name || $0.id == name }) {
                if tools[idx].isEnabled != enabled {
                    tools[idx].isEnabled = enabled
                    changed = true
                }
            }
        }
        if changed {
            appState.tools = tools
            PersistenceManager.shared.saveTools(tools)
        }
    }

    private var advancedPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Autonomous ReAct Loop & Hierarchy", description: "Multi-agent hierarchy limits and deep ReAct execution cycles", icon: "point.3.connected.trianglepath.dotted") {
                SettingsRow(title: "Max Autonomous Iteration Loop (\(appState.settings.maxAutonomousIterations) turns)", subtitle: "Maximum iterative ReAct tool calls per agent turn (1 - 50)", icon: "arrow.triangle.2.circlepath") {
                    Stepper("", value: $appState.settings.maxAutonomousIterations, in: 1...50)
                }

                SettingsRow(title: "Sub-agent Step Budget (\(appState.settings.subAgentStepBudget) steps)", subtitle: "Rounds a delegated sub-agent gets before it must report back (1 - 50)", icon: "person.2.badge.gearshape") {
                    Stepper("", value: $appState.settings.subAgentStepBudget, in: 1...50)
                }

                SettingsRow(title: "Sub-agent Time Limit (\(appState.settings.subAgentTimeoutMinutes) min)", subtitle: "Working time a delegated sub-agent gets before it reports what it has; time queued for the local model is not counted (1 - 60 minutes)", icon: "timer") {
                    Stepper("", value: $appState.settings.subAgentTimeoutMinutes, in: 1...60)
                }

                SettingsRow(title: "Plan Mode", subtitle: "Block writes/shell/mutating MCP until exit_plan_mode (Radiant parity)", icon: "list.clipboard") {
                    Toggle("", isOn: $appState.settings.planModeEnabled)
                        .toggleStyle(.switch)
                }
            }

            WorkspaceRulesCard(appState: appState)

            SettingsCard(title: "Autonomous ReAct Loop & Hierarchy (continued)", description: "Token budgets and multi-agent limits", icon: "gauge.with.dots.needle.67percent") {
                SettingsRow(title: "Max Turn Tokens (\(appState.settings.maxTurnTokens / 1000)k)", subtitle: "Halt a single turn when estimated token use exceeds this budget", icon: "gauge.with.dots.needle.67percent") {
                    Stepper("", value: $appState.settings.maxTurnTokens, in: 100_000...5_000_000, step: 100_000)
                }

                SettingsRow(title: "Allow Sub-Agent Spawning", subtitle: "Enable lead agents to launch child agents", icon: "person.2.fill") {
                    Toggle("", isOn: $appState.settings.allowSubAgentCreation)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Max Global Nesting Depth (\(appState.settings.maxGlobalSubAgentDepth))", subtitle: "Maximum chain of child agents", icon: "arrow.down.right.and.arrow.up.left") {
                    Stepper("", value: $appState.settings.maxGlobalSubAgentDepth, in: 1...5)
                }

                SettingsRow(title: "Multi-Agent Collaboration Room", subtitle: "Show the collaboration tab in AI Agents", icon: "bubble.left.and.exclamationmark.bubble.right.fill") {
                    Toggle("", isOn: $appState.settings.enableAgentCollaborationRoom)
                        .toggleStyle(.switch)
                }

                // The Agent Messages tab was always shown whatever this said.
                SettingsRow(title: "Agent Messages Inspector Tab", subtitle: "Show the inter-agent communication log", icon: "list.bullet.rectangle") {
                    Toggle("", isOn: $appState.settings.showInterAgentCommunicationLogs)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 6. AI Providers
    private var aiProvidersPage: some View {
        VStack(spacing: 16) {
            ForEach(appState.providers) { prov in
                SettingsCard(title: prov.name, description: "\(prov.baseUrl) • \(prov.models.count) models", icon: prov.kind.icon) {
                    HStack(spacing: 10) {
                        if prov.type == .cloud {
                            SecureField("API Key", text: Binding(
                                get: { prov.apiKey },
                                set: { val in
                                    var updated = prov
                                    updated.apiKey = val
                                    appState.saveProvider(updated)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        Button("Fetch Models") {
                            appState.refreshModels(for: prov)
                        }

                        Button("Test") {
                            Task {
                                let ok = (try? await ProviderRouter.shared.client(for: prov).testConnection(provider: prov)) ?? false
                                appState.showToast(ok ? "\(prov.name): Connected!" : "\(prov.name): Failed")
                            }
                        }

                        Toggle("", isOn: Binding(
                            get: { prov.isEnabled },
                            set: { val in
                                var updated = prov
                                updated.isEnabled = val
                                appState.saveProvider(updated)
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                }
            }
        }
        .onAppear { appState.loadProviderKeysForDisplay() }
    }

    // 7. Appearance
    private var appearancePage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Theme & Palette", description: "Visual appearance of SwiftOpenWork", icon: "paintbrush.fill") {
                SettingsRow(title: "Theme Mode", subtitle: "Select window theme styling", icon: "circle.lefthalf.filled") {
                    Picker("", selection: $appState.settings.theme) {
                        ForEach(AppTheme.allCases) { th in
                            Text(th.displayName).tag(th)
                        }
                    }
                    .frame(width: 180)
                }

                SettingsRow(title: "Accent Color", subtitle: "Highlight and brand color", icon: "eyedropper.full") {
                    Picker("", selection: $appState.settings.accentColor) {
                        ForEach(AccentColorChoice.allCases) { ch in
                            Text(ch.displayName).tag(ch)
                        }
                    }
                    .frame(width: 180)
                }

                SettingsRow(title: "Editor Font Size (\(appState.settings.editorFontSize)pt)", subtitle: "Font scale for code and chat text", icon: "textformat.size") {
                    Stepper("", value: $appState.settings.editorFontSize, in: 10...22)
                }

                SettingsRow(title: "Inline AI Suggestions", subtitle: "Ghost text in the code editor when you pause typing. Tab accepts, Esc dismisses. The local model is used only when idle.", icon: "sparkles") {
                    Toggle("", isOn: $appState.settings.inlineSuggestionsEnabled)
                        .toggleStyle(.switch)
                }

                // Stored as settings.inlineSuggestionProviderId and settings.inlineSuggestionModelId.
                SettingsRow(title: "Suggestion Model", subtitle: "Automatic uses your chat model only when it runs on this Mac. Code is sent to a cloud model only if you choose one here.", icon: "cpu") {
                    Picker("", selection: SuggestionModelOption.binding(appState)) {
                        Text("Automatic").tag(SuggestionModelOption.automatic)
                        ForEach(SuggestionModelOption.options(from: appState.providers), id: \.self) { option in
                            Text(option.label(in: appState.providers)).tag(option)
                        }
                    }
                    .frame(width: 260)
                    .disabled(!appState.settings.inlineSuggestionsEnabled)
                }

                SettingsRow(title: "Translucent Window Background", subtitle: "Show macOS vibrancy behind the sidebar and inspector", icon: "macwindow") {
                    Toggle("", isOn: $appState.settings.useTranslucentBackground)
                        .toggleStyle(.switch)
                }

                // `compactSidebar` was stored with no reader and no control anywhere.
                SettingsRow(title: "Compact Sidebar", subtitle: "Tighter rows and no workspace subtitle", icon: "sidebar.left") {
                    Toggle("", isOn: $appState.settings.compactSidebar)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // 8. Environment
    private var environmentPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Environment Variables", description: "Injected into agent shells and MCP processes", icon: "terminal.fill") {
                ForEach(Array(appState.settings.customEnvironmentVariables.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(appState.settings.customEnvironmentVariables[key] ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Button {
                            appState.settings.customEnvironmentVariables.removeValue(forKey: key)
                            appState.updateSettings(appState.settings)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red).font(.system(size: 11))
                        }
                        .buttonStyle(.hitTestable)
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.3))
                    .cornerRadius(6)
                }

                HStack {
                    TextField("KEY", text: $newEnvKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("VALUE", text: $newEnvVal)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        guard !newEnvKey.isEmpty else { return }
                        appState.settings.customEnvironmentVariables[newEnvKey] = newEnvVal
                        appState.updateSettings(appState.settings)
                        newEnvKey = ""
                        newEnvVal = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // 9. Updates
    private var updatesPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Software Updates & Branding", description: "SwiftOpenWork standalone desktop client", icon: "arrow.triangle.2.circlepath") {
                HStack(spacing: 14) {
                    // Was a hardcoded absolute path into a volume on one developer's machine.
                    if let appIconImage = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage {
                        Image(nsImage: appIconImage)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .cornerRadius(10)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("SwiftOpenWork")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        // Was hardcoded "1.0.0" while the shipped release was 1.1.0.
                        Text("Version \(Self.appVersionString) (Darwin arm64)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Autonomous Multi-Agent AI Engineering Platform")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                    }

                    Spacer()

                    Button(checkingForUpdates ? "Checking…" : "Check for Updates") {
                        checkingForUpdates = true
                        Task { @MainActor in
                            updateOutcome = await UpdateChecker.check()
                            checkingForUpdates = false
                        }
                    }
                    .disabled(checkingForUpdates)
                }
                .padding(.vertical, 4)

                if let updateOutcome {
                    updateOutcomeRow(updateOutcome)
                }

                Divider()

                // Checks the GitHub releases feed at launch, at most once a day. It reports and
                // links; it never downloads or installs anything.
                SettingsRow(title: "Auto-Check Updates", subtitle: "Check GitHub releases at launch, at most once a day", icon: "bell") {
                    Toggle("", isOn: $appState.settings.autoCheckForUpdates)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    @ViewBuilder
    private func updateOutcomeRow(_ outcome: UpdateChecker.Outcome) -> some View {
        switch outcome {
        case let .upToDate(current):
            Label("Up to date — \(current) is the latest release.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
        case let .available(current, latest, url):
            HStack(spacing: 8) {
                Label("\(latest) is available (you have \(current)).", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Spacer()
                Button("View Release") { NSWorkspace.shared.open(url) }
            }
        case let .failed(reason):
            // Never "up to date": a check that could not be made has not verified anything.
            Label("Could not check: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .textSelection(.enabled)
        }
    }

    // 10. Recovery
    private var recoveryPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Backup & Data Export", description: "Export or restore all workspaces, sessions, and agents", icon: "arrow.down.doc.fill") {
                SettingsRow(title: "Export Archive", subtitle: "Save JSON backup archive to disk", icon: "square.and.arrow.up") {
                    Button("Export Backup...") {
                        if let url = StorageService.shared.exportBackup() {
                            appState.showToast("Backup saved to \(url.path)")
                        }
                    }
                }
            }

            SettingsCard(title: "Danger Zone", description: "Erase all local data and restore defaults", icon: "exclamationmark.triangle.fill") {
                SettingsRow(title: "Factory Reset", subtitle: "Wipes sessions, custom agents, memories, and resets configuration", icon: "trash") {
                    Button("Reset All Data...", role: .destructive) {
                        showingResetAlert = true
                    }
                }
            }
        }
        .alert("Confirm Factory Reset", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                StorageService.shared.clearAllData()
                appState.loadAll()
                appState.showToast("Data reset to defaults")
            }
        } message: {
            Text("This will permanently clear all custom sessions, agents, and memories.")
        }
    }

    // 11. Debug
    private var debugPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Developer Options", description: "Runtime diagnostic flags and inspect mode", icon: "ant.fill") {
                SettingsRow(title: "Developer Mode", subtitle: "Enable advanced telemetry and model diagnostics", icon: "hammer") {
                    Toggle("", isOn: $appState.settings.developerMode)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Verbose Logging", subtitle: "Log raw SSE chunks and tool payloads to the unified log (subsystem io.github.foscoe63.SwiftOpenWork)", icon: "doc.plaintext") {
                    Toggle("", isOn: $appState.settings.verboseLogging)
                        .toggleStyle(.switch)
                }
            }

            // `developerMode` was stored, was labelled "Enable advanced telemetry and model
            // diagnostics", and nothing read it — this card was here either way. It gates the
            // card rather than the page, or the switch would hide itself.
            if appState.settings.developerMode {
                SettingsCard(title: "Live Runtime Telemetry", description: "Real-time state snapshot", icon: "chart.xyaxis.line") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Storage Path: \(StorageService.shared.baseDirectory.path)")
                            .font(.system(size: 11, design: .monospaced))
                        Text("• Registered Agents: \(appState.agents.count)")
                            .font(.system(size: 11, design: .monospaced))
                        Text("• Stored Sessions: \(appState.sessions.count)")
                            .font(.system(size: 11, design: .monospaced))
                        Text("• Enabled Tools: \(appState.tools.filter { $0.isEnabled }.count)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
                }

                // The "model diagnostics" half of that label. The search roots in particular
                // existed only inside a not-downloaded error message, so a user whose library
                // sits somewhere unusual had no way to see where the app looked.
                SettingsCard(title: "MLX Diagnostics", description: "Resident models, memory policy, and every directory searched for weights", icon: "cpu") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Resident models: \(appState.loadedMLXModelIds.isEmpty ? "none" : appState.loadedMLXModelIds.joined(separator: ", "))")
                            .font(.system(size: 11, design: .monospaced))
                        Text(String(
                            format: "• GPU budget: %.0f%% of %.1f GB = %.1f GB",
                            appState.settings.mlxGpuMemoryBudgetRatio * 100,
                            LocalMLXEngine.physicalRAMGB,
                            LocalMLXEngine.physicalRAMGB * appState.settings.mlxGpuMemoryBudgetRatio
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        Text("• Discovered models: \(appState.localMLXModels.filter { $0.isDownloaded }.count)")
                            .font(.system(size: 11, design: .monospaced))
                        Text("• Search roots:")
                            .font(.system(size: 11, design: .monospaced))
                        ForEach(LocalMLXEngine.knownMLXSearchRoots(settings: appState.settings), id: \.self) { root in
                            Text("    \(root.path)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
                }
            }
        }
    }

    /// Skills that live in the repository rather than in the app.
    ///
    /// Global skills apply to every workspace, which is the wrong scope for anything specific to
    /// one codebase. These are read from `.swiftopenwork/skills/` in the active workspace on every
    /// turn, so they can be edited with the rest of the project and reviewed in a pull request.
    private var projectSkillsCard: some View {
        let workspace = appState.currentWorkspace
        let folder = ProjectSkills.folder(in: workspace.folderPath)
        let folderExists = !ProjectSkills.existingFolders(in: workspace.folderPath).isEmpty

        return SettingsCard(
            title: "Project Skills (\(projectSkills.count))",
            description: "Skills stored inside '\(workspace.name)' and loaded only while it is the active workspace. Edited on disk, versioned with the project.",
            icon: "folder.badge.gearshape"
        ) {
            HStack(spacing: 8) {
                Text(folder)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)

                Spacer()

                if folderExists {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Create Skills Folder") {
                        createProjectSkillsFolder(in: workspace.folderPath)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(workspace.folderPath.isEmpty)
                }

                Button("Reload") { refreshProjectSkills() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if projectSkills.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text(folderExists
                         ? "No skills in this project yet."
                         : "This project has no skills folder yet.")
                        .font(.system(size: 12, weight: .medium))
                    Text("Add a folder per skill containing a SKILL.md file. They load on the next message — no import step.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(projectSkills) { skill in
                        HStack(spacing: 10) {
                            Image(systemName: skill.source.icon)
                                .font(.system(size: 13))
                                .foregroundColor(skill.isEnabled ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.system(size: 12, weight: .semibold))
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                if let path = skill.filePath {
                                    Text(displayPath(path, relativeTo: workspace.folderPath))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.8))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }

                            Spacer()

                            // Enabling happens in the file's front matter, not here: a toggle in
                            // settings would be app state that silently disagrees with the
                            // repository everyone else checks out.
                            Text(skill.isEnabled ? "Enabled" : "Disabled (enabled: false)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(skill.isEnabled ? .green : .secondary)

                            if let path = skill.filePath {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                        .padding(10)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .onAppear { refreshProjectSkills() }
        .onChange(of: appState.activeWorkspaceId) { _, _ in refreshProjectSkills() }
    }

    private func refreshProjectSkills() {
        projectSkills = ProjectSkills.load(workspacePath: appState.currentWorkspace.folderPath)
    }

    private func createProjectSkillsFolder(in workspacePath: String) {
        do {
            let created = try ProjectSkills.ensureFolder(in: workspacePath)
            refreshProjectSkills()
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: created)])
            appState.showToast("Created \(ProjectSkills.relativePath)")
        } catch {
            appState.showToast("Could not create the skills folder: \(error.localizedDescription)")
        }
    }

    /// `.swiftopenwork/skills/foo/SKILL.md` reads better than the absolute path in a narrow row.
    private func displayPath(_ path: String, relativeTo root: String) -> String {
        guard !root.isEmpty, path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // 14. Skills & MCP
    private var skillsPage: some View {
        VStack(spacing: 20) {
            // MARK: - AGENT SKILLS SECTION
            SettingsCard(
                title: "Agent Skills (\(appState.skills.count))",
                description: "Modular instructions and domain knowledge that enhance agent autonomy",
                icon: "sparkles"
            ) {
                // Actions & Filter Bar
                HStack(spacing: 10) {
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        TextField("Search skills...", text: $skillSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !skillSearchText.isEmpty {
                            Button {
                                skillSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.hitTestable)
                        }
                    }
                    .padding(6)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .cornerRadius(6)

                    Spacer()

                    // Add Skill Menu with Multiple Ways
                    Menu {
                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Create Custom Skill...", systemImage: "pencil.and.outline")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select SKILL.md or Markdown File"
                            if let mdType = UTType(filenameExtension: "md") {
                                panel.allowedContentTypes = [.plainText, mdType]
                            } else {
                                panel.allowedContentTypes = [.plainText]
                            }
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importSkillFromFile(url: url)
                            }
                        } label: {
                            Label("Import SKILL.md File...", systemImage: "doc.badge.plus")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select Folder Containing Skills"
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importSkillsFromFolder(url: url)
                            }
                        } label: {
                            Label("Import from Directory / Folder...", systemImage: "folder.badge.plus")
                        }

                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Import from URL / GitHub...", systemImage: "globe")
                        }

                        Divider()

                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Browse Skill Templates...", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("Add Skill")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 4)

                // List of Skills
                let filteredSkills = appState.skills.filter {
                    skillSearchText.isEmpty ||
                    $0.name.localizedCaseInsensitiveContains(skillSearchText) ||
                    $0.description.localizedCaseInsensitiveContains(skillSearchText) ||
                    $0.category.localizedCaseInsensitiveContains(skillSearchText)
                }

                if filteredSkills.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text(skillSearchText.isEmpty ? "No agent skills installed yet." : "No skills match '\(skillSearchText)'")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Add skills to equip your autonomous agents with specialized instructions, best practices, and domain workflows.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredSkills) { skill in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: skill.source.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(skill.name)
                                            .font(.system(size: 12, weight: .bold))

                                        Text(skill.category)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        Text(skill.source.displayName)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.secondary.opacity(0.12))
                                            .cornerRadius(4)
                                    }

                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    if let path = skill.filePath {
                                        Text(path)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button("Inspect / Edit") {
                                        selectedSkillForDetail = skill
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { skill.isEnabled },
                                        set: { val in
                                            var updated = skill
                                            updated.isEnabled = val
                                            appState.saveSkill(updated)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deleteSkill(skill)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.hitTestable)
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // MARK: - PROJECT SKILLS SECTION
            projectSkillsCard

            // MARK: - MODEL CONTEXT PROTOCOL (MCP) SERVERS SECTION
            SettingsCard(
                title: "Model Context Protocol (MCP) Servers (\(appState.settings.mcpServers.count))",
                description: "Extend autonomous agents with stdio processes, remote HTTP/SSE gateways, and WebSocket tools. Enable only servers you trust — cold starts no longer block chat.",
                icon: "network"
            ) {
                HStack {
                    Text("Configured MCP Servers")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()

                    Button(mcpStatusBusy ? "Probing…" : "Refresh Status") {
                        refreshMcpStatus(probe: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(mcpStatusBusy)

                    Button("Restore Defaults") {
                        appState.settings.mcpServers = AppSettings.defaultMCPServers
                        appState.updateSettings(appState.settings)
                        appState.showToast("Restored standard MCP servers (disabled by default)")
                        refreshMcpStatus(probe: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        selectedMcpForEdit = nil
                        showingAddMcp = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                            Text("Add MCP Server...")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }

                if appState.settings.mcpServers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector.slash")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No Model Context Protocol servers configured.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Connect servers like @modelcontextprotocol/server-filesystem, memory, sqlite, or remote HTTP/SSE endpoints.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.settings.mcpServers) { mcp in
                            let report = mcpStatusReports.first(where: { $0.id == mcp.id })
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: mcp.transportType.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(mcp.name)
                                            .font(.system(size: 12, weight: .bold))

                                        Text(mcp.transportType.displayName)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        mcpStatusBadge(for: mcp, report: report)

                                        if !mcp.env.isEmpty {
                                            Text("\(mcp.env.count) ENV")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Color.secondary.opacity(0.12))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if mcp.transportType == .stdio {
                                        Text("\(mcp.command) \(mcp.args.joined(separator: " "))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text(mcp.url)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    if !mcp.workingDirectory.isEmpty {
                                        Text("cwd: \(mcp.workingDirectory)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }

                                    if let err = report?.error, !err.isEmpty {
                                        Text(err)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(.red.opacity(0.85))
                                            .lineLimit(3)
                                    } else if let tools = report?.tools, !tools.isEmpty {
                                        mcpToolGateSection(server: mcp, advertised: tools)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button(mcpStatusBusy ? "…" : "Test") {
                                        testMcpServer(mcp)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(mcpStatusBusy || !mcp.isEnabled)

                                    Button("Configure") {
                                        selectedMcpForEdit = mcp
                                        showingAddMcp = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { mcp.isEnabled },
                                        set: { val in
                                            var updated = mcp
                                            updated.isEnabled = val
                                            appState.saveMcpServer(updated)
                                            refreshMcpStatus(probe: false)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deleteMcpServer(mcp)
                                        refreshMcpStatus(probe: false)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.hitTestable)
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .task {
                refreshMcpStatus(probe: false)
            }
        }
        .sheet(isPresented: $showingAddSkill) {
            AddSkillModalView(appState: appState, isPresented: $showingAddSkill)
        }
        .sheet(item: $selectedSkillForDetail) { skill in
            SkillDetailModalView(appState: appState, isPresented: Binding(
                get: { selectedSkillForDetail != nil },
                set: { if !$0 { selectedSkillForDetail = nil } }
            ), skill: skill)
        }
        .sheet(isPresented: $showingAddMcp) {
            McpServerEditModalView(
                appState: appState,
                isPresented: $showingAddMcp,
                editingConfig: selectedMcpForEdit
            )
        }
    }

    // 15. Memory
    private var memoryPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Long-Term Workspace Memory", description: "Currently holding \(appState.memories.count) memory items", icon: "brain") {
                ForEach(appState.memories) { mem in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mem.key)
                                .font(.system(size: 12, weight: .bold))
                            Text(mem.content)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.memories.removeAll(where: { $0.id == mem.id })
                            PersistenceManager.shared.saveMemories(appState.memories)
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red).font(.system(size: 11))
                        }
                        .buttonStyle(.hitTestable)
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: appState.settings.theme).opacity(0.3))
                    .cornerRadius(6)
                }

                Button("Clear All Memories", role: .destructive) {
                    appState.memories.removeAll()
                    PersistenceManager.shared.saveMemories(appState.memories)
                    appState.showToast("Memories cleared")
                }
            }
        }
    }

    // MARK: - Helpers
    /// Per-tool switches for one connected server. Collapsed to a summary line until opened, so a
    /// server advertising 40 tools does not bury the rest of the list.
    @ViewBuilder
    private func mcpToolGateSection(server: MCPServerConfig, advertised: [String]) -> some View {
        let expanded = expandedMcpToolLists.contains(server.id)
        let offCount = advertised.filter { server.disabledTools.contains($0) }.count

        VStack(alignment: .leading, spacing: 5) {
            Button {
                if expanded {
                    expandedMcpToolLists.remove(server.id)
                } else {
                    expandedMcpToolLists.insert(server.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Tools: \(advertised.count)")
                        .font(.system(size: 10.5))
                    if offCount > 0 {
                        Text("\(offCount) off")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.18))
                            .cornerRadius(4)
                    }
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.hitTestable)

            if !expanded {
                Text(advertised.prefix(8).joined(separator: ", ") + (advertised.count > 8 ? "…" : ""))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(2)
            } else {
                HStack(spacing: 8) {
                    Button("Enable all") {
                        var updated = server
                        MCPToolGate.setAllTools(true, advertised: advertised, in: &updated)
                        appState.saveMcpServer(updated)
                    }
                    Button("Disable all") {
                        var updated = server
                        MCPToolGate.setAllTools(false, advertised: advertised, in: &updated)
                        appState.saveMcpServer(updated)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

                ForEach(advertised.sorted(), id: \.self) { toolName in
                    Toggle(isOn: Binding(
                        get: { MCPToolGate.isToolEnabled(server: server, toolName: toolName) },
                        set: { isOn in
                            var updated = server
                            MCPToolGate.setTool(isOn, named: toolName, in: &updated)
                            appState.saveMcpServer(updated)
                        }
                    )) {
                        Text(toolName)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .disabled(!server.isEnabled)
                }
            }
        }
    }

    private func mcpStatusBadge(for mcp: MCPServerConfig, report: MCPServerReport?) -> some View {
        let label: String
        let color: Color
        if !mcp.isEnabled {
            label = "off"
            color = .secondary
        } else if let report, report.connected {
            label = "✓ \(report.toolCount) tools"
            color = .green
        } else if let report, report.error != nil {
            label = "error"
            color = .red
        } else if report?.status == .connecting {
            label = "connecting"
            color = .orange
        } else {
            label = "idle"
            color = .secondary
        }
        return Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    private func refreshMcpStatus(probe: Bool) {
        mcpStatusBusy = true
        Task { @MainActor in
            let reports = await MCPClientManager.shared.mcpStatusReports(probe: probe)
            mcpStatusReports = reports
            mcpStatusBusy = false
            if probe {
                let connected = reports.filter(\.connected).count
                let errors = reports.filter { $0.error != nil }.count
                appState.showToast("MCP status: \(connected) connected, \(errors) errors")
            }
        }
    }

    private func testMcpServer(_ mcp: MCPServerConfig) {
        guard mcp.isEnabled else {
            appState.showToast("Enable '\(mcp.name)' before testing")
            return
        }
        mcpStatusBusy = true
        Task { @MainActor in
            do {
                let tools = try await MCPClientManager.shared.startServer(config: mcp)
                let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
                mcpStatusReports = reports
                appState.showToast("MCP '\(mcp.name)' OK — \(tools.count) tools")
            } catch {
                let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
                mcpStatusReports = reports
                appState.showToast("MCP '\(mcp.name)' failed: \(error.localizedDescription)")
            }
            mcpStatusBusy = false
        }
    }

    /// The version this build actually is, from its own bundle.
    ///
    /// The About row hardcoded "1.0.0" while the shipped release was 1.1.0. `project.yml` now sets
    /// MARKETING_VERSION, so the string here and the bundle agree by construction.
    static var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        default: return "unknown"
        }
    }

    /// Push the new-agent defaults onto every existing agent.
    ///
    /// Without this the settings above are reachable only by creating a new agent, which is a
    /// strange thing to have to do to change the temperature of the one you already use.
    private func applyAgentDefaultsToAllAgents() {
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

    private func tabTitle(for tab: String) -> String {
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
        default: return "Settings"
        }
    }

    private func tabDescription(for tab: String) -> String {
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
        default: return "Configure SwiftOpenWork preferences"
        }
    }
}

// MARK: - Edit Workspace Modal
public struct EditWorkspaceModalView: View {
    @ObservedObject var appState: AppState
    @State var draft: Workspace
    @Binding var isPresented: Bool

    public init(appState: AppState, workspace: Workspace, isPresented: Binding<Bool>) {
        self.appState = appState
        self._draft = State(initialValue: workspace)
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Workspace")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Configure directory path, assigned agent, and pipeline automation")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .font(.system(size: 16))
                }
                .buttonStyle(.hitTestable)
            }
            .padding(18)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace Name")
                            .font(.system(size: 11, weight: .semibold))
                        TextField("Workspace Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $draft.category) {
                            ForEach(WorkspaceCategory.allCases) { cat in
                                Label(cat.displayName, systemImage: cat.icon).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Assigned Agent
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned Agent Sandbox")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: Binding(
                            get: { draft.assignedAgentId ?? "" },
                            set: { draft.assignedAgentId = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("None (Shared Workspace)").tag("")
                            ForEach(appState.agents) { ag in
                                Text("\(ag.name) (\(ag.role))").tag(ag.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Workspace Directory Path
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Root Directory Path (External SSD / Drive / Custom Folder)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            TextField("Folder Path (e.g. /Volumes/ExternalSSD/Workspaces)", text: $draft.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))

                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.prompt = "Select Workspace Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    draft.folderPath = url.path
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        // Quick Drive / Location Shortcuts
                        HStack(spacing: 8) {
                            Button {
                                let panel = NSOpenPanel()
                                panel.directoryURL = URL(fileURLWithPath: "/Volumes")
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.prompt = "Choose External SSD Folder"
                                if panel.runModal() == .OK, let url = panel.url {
                                    draft.folderPath = url.path
                                }
                            } label: {
                                Label("Browse External SSD (/Volumes)...", systemImage: "externaldrive")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button {
                                let url = URL(fileURLWithPath: draft.folderPath)
                                appState.ensureWorkspaceFolderExists(for: draft)
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                            } label: {
                                Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    Divider()

                    // Staged Pipeline Automation
                    Toggle("Enable Staged Pipeline ('input/' & 'output/' automation)", isOn: $draft.isPipelineStagingEnabled)
                        .font(.system(size: 11.5, weight: .semibold))
                        .toggleStyle(.switch)

                    if draft.isPipelineStagingEnabled {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Input Subfolder")
                                    .font(.system(size: 10, weight: .medium))
                                TextField("input", text: $draft.inputFolderPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output Subfolder")
                                    .font(.system(size: 10, weight: .medium))
                                TextField("output", text: $draft.outputFolderPath)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .padding(18)
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Workspace") {
                    draft.icon = draft.category.icon
                    appState.saveWorkspace(draft)
                    if appState.activeWorkspaceId == draft.id {
                        appState.ensureWorkspaceFolderExists(for: draft)
                    }
                    appState.showToast("Saved workspace '\(draft.name)'")
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))
        }
        .frame(width: 520, height: 500)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
