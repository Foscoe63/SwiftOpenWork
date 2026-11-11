import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The MLX local-model settings page.

extension SettingsView {
    // MLX Settings Page (Parity with Osaurus & GrizzyClaw)
    var mlxSettingsPage: some View {
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
}
