import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The Permissions page and watch folders.

extension SettingsView {
    // 3. Permissions
    var permissionsPage: some View {
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

                SettingsRow(title: "Shell Sandbox", subtitle: "Run commands under macOS Seatbelt so writes outside the workspace, and optionally network access, are blocked by the OS itself. Plain xcodebuild and swift build/test runs are exempt, since they sandbox their own plugins", icon: "shield.lefthalf.filled") {
                    Picker("", selection: $appState.settings.shellSandboxMode) {
                        ForEach(ShellSandboxMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .frame(width: 240)
                }
            }

            SemanticSearchSettingsCard(
                appState: appState,
                enabled: $appState.settings.semanticSearchEnabled,
                modelId: $appState.settings.embeddingModelId
            )

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
    var watchFoldersPage: some View {
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
}
