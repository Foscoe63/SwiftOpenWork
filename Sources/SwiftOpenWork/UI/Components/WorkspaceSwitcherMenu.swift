import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Shared workspace picker used by the sidebar ("Core Workspaces & Research") and the chat header.
/// Both bind to `appState.activeWorkspaceId`, so selections stay in sync.
public struct WorkspaceSwitcherMenu<LabelContent: View>: View {
    @ObservedObject var appState: AppState
    var onSelectWorkspace: (String) -> Void
    var showsManagementActions: Bool
    @ViewBuilder var label: () -> LabelContent

    @State private var showingWorkspaceSheet = false
    /// The workspace the remove submenu picked, held until the alert confirms it.
    @State private var workspacePendingRemoval: Workspace?
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceCategory: WorkspaceCategory = .general
    @State private var newWorkspaceAgentId: String = ""
    @State private var newWorkspaceFolderPath: String = ""
    @State private var newWorkspaceTemplate: WorkspaceBootstrap.StarterTemplate = .empty

    public init(
        appState: AppState,
        showsManagementActions: Bool = true,
        onSelectWorkspace: @escaping (String) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.appState = appState
        self.showsManagementActions = showsManagementActions
        self.onSelectWorkspace = onSelectWorkspace
        self.label = label
    }

    public var body: some View {
        Menu {
            let coreWorkspaces = appState.workspaces.filter {
                $0.category == .general || $0.category == .research || $0.category == .project
            }
            if !coreWorkspaces.isEmpty {
                Section("Core Workspaces & Research") {
                    ForEach(coreWorkspaces) { ws in
                        workspaceButton(ws)
                    }
                }
            }

            let agentWorkspaces = appState.workspaces.filter { $0.category == .agent }
            if !agentWorkspaces.isEmpty {
                Section("Agent Workspaces") {
                    ForEach(agentWorkspaces) { ws in
                        workspaceButton(ws)
                    }
                }
            }

            if showsManagementActions {
                Divider()

                Button {
                    showingWorkspaceSheet = true
                } label: {
                    Label("Add New Workspace...", systemImage: "plus")
                }

                Button {
                    openExistingProject()
                } label: {
                    Label("Open Existing Project...", systemImage: "folder")
                }

                if !appState.workspaces.isEmpty {
                    Menu {
                        ForEach(appState.workspaces) { ws in
                            Button(role: .destructive) {
                                workspacePendingRemoval = ws
                            } label: {
                                Label(ws.name, systemImage: ws.icon)
                            }
                        }
                    } label: {
                        Label("Remove Workspace", systemImage: "trash")
                    }
                }

                Button {
                    appState.generateWorkspacesForAgents()
                } label: {
                    Label("Auto-Generate Workspaces for All Agents", systemImage: "sparkles")
                }

                Button {
                    appState.navigationDestination = .settings
                    appState.settingsTab = "general"
                } label: {
                    Label("Workspace Configuration...", systemImage: "gearshape")
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $showingWorkspaceSheet) {
            newWorkspaceModal
        }
        .alert(
            "Remove '\(workspacePendingRemoval?.name ?? "")'?",
            isPresented: Binding(
                get: { workspacePendingRemoval != nil },
                set: { if !$0 { workspacePendingRemoval = nil } }
            ),
            presenting: workspacePendingRemoval
        ) { ws in
            Button("Remove", role: .destructive) {
                appState.deleteWorkspace(ws)
                workspacePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { workspacePendingRemoval = nil }
        } message: { ws in
            // The distinction people get wrong, and the reason this is an alert rather than a
            // plain menu item: nothing on disk is touched.
            Text("This removes the workspace from \(AppIdentity.displayName). The folder and its files stay on disk at \(ws.folderPath.isEmpty ? "their current location" : ws.folderPath).")
        }
    }

    /// Point a workspace at a folder that already exists, rather than scaffolding a new one.
    private func openExistingProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Open Existing Project"
        panel.prompt = "Open Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ws = appState.openExistingProject(at: url)
        onSelectWorkspace(ws.id)
    }

    @ViewBuilder
    private func workspaceButton(_ ws: Workspace) -> some View {
        Button {
            onSelectWorkspace(ws.id)
        } label: {
            HStack {
                Image(systemName: ws.icon)
                Text(ws.name)
                if ws.id == appState.activeWorkspaceId {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var newWorkspaceModal: some View {
        VStack(spacing: 16) {
            Text("Create Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Name")
                        .font(.system(size: 11, weight: .semibold))
                    TextField("e.g. AI & Agent Research, Swift Projects", text: $newWorkspaceName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Category")
                        .font(.system(size: 11, weight: .semibold))
                    Picker("", selection: $newWorkspaceCategory) {
                        ForEach(WorkspaceCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.icon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                WorkspaceTemplatePicker(template: $newWorkspaceTemplate)

                if newWorkspaceCategory == .agent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned Agent Sandbox")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $newWorkspaceAgentId) {
                            Text("None (Shared Workspace)").tag("")
                            ForEach(appState.agents) { ag in
                                Text("\(ag.name) (\(ag.role))").tag(ag.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Directory Path (External SSD / Custom Folder / Project)")
                        .font(.system(size: 11, weight: .semibold))

                    HStack(spacing: 6) {
                        TextField(
                            "e.g. /Volumes/ExternalSSD/Workspaces or project folder",
                            text: Binding(
                                get: {
                                    if newWorkspaceFolderPath.isEmpty && !newWorkspaceName.isEmpty {
                                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                                        let baseWs = (home as NSString).appendingPathComponent(AppIdentity.workspacesRelativePath)
                                        return (baseWs as NSString).appendingPathComponent(newWorkspaceName.replacingOccurrences(of: " ", with: "-"))
                                    }
                                    return newWorkspaceFolderPath
                                },
                                set: { newWorkspaceFolderPath = $0 }
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
                            panel.prompt = "Choose Workspace Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                newWorkspaceFolderPath = url.path
                                if newWorkspaceName.isEmpty {
                                    newWorkspaceName = url.lastPathComponent
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
                    showingWorkspaceSheet = false
                    resetNewWorkspaceFields()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Workspace") {
                    guard !newWorkspaceName.isEmpty else { return }
                    let ws = appState.createWorkspace(
                        name: newWorkspaceName,
                        category: newWorkspaceCategory,
                        assignedAgentId: newWorkspaceAgentId,
                        folderPath: newWorkspaceFolderPath,
                        template: newWorkspaceTemplate
                    )
                    onSelectWorkspace(ws.id)
                    showingWorkspaceSheet = false
                    resetNewWorkspaceFields()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func resetNewWorkspaceFields() {
        newWorkspaceName = ""
        newWorkspaceCategory = .general
        newWorkspaceAgentId = ""
        newWorkspaceFolderPath = ""
        newWorkspaceTemplate = .empty
    }
}
