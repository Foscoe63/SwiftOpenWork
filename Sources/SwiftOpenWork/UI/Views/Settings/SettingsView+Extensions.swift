import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The Extensions & Plugins page.

extension SettingsView {
    // 4. Extensions & Plugins Page
    var extensionsPage: some View {
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
}
