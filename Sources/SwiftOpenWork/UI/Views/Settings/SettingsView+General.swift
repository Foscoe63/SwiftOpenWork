import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The General page.

extension SettingsView {
    // 1. General
    var generalPage: some View {
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
}
