import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// Appearance, Environment, Updates, Recovery, Debug and Memory.

extension SettingsView {
    // 7. Appearance
    var appearancePage: some View {
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
    var environmentPage: some View {
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
    var updatesPage: some View {
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
    func updateOutcomeRow(_ outcome: UpdateChecker.Outcome) -> some View {
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
    var recoveryPage: some View {
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
    var debugPage: some View {
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

    // 15. Memory
    var memoryPage: some View {
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
}
