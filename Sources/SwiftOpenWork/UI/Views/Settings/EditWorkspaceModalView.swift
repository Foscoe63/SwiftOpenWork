import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

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
