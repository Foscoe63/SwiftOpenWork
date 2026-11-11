import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The Preferences page.

extension SettingsView {
    // 2. Preferences
    var preferencesPage: some View {
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

                SettingsRow(title: "Auto-Detect & Optimize for Local Models", subtitle: "Automatically apply higher penalties and ReAct safety for MLX, Ollama, and local endpoints. Turns that use tools never get penalties: they break code edits", icon: "wand.and.stars") {
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
                    SettingsRow(title: "Compaction Threshold (\(appState.settings.contextCompactionThresholdTokens / 1000)k tokens)", subtitle: "Transcript size that triggers a summarize pass (never above 70% of the model's window)", icon: "arrow.down.right.and.arrow.up.left") {
                        Stepper("", value: $appState.settings.contextCompactionThresholdTokens, in: 8000...256_000, step: 4000)
                    }

                    SettingsRow(title: "Compaction Summary Model", subtitle: "A local model writes short notes on the steps compaction drops, beside the exact list of files and commands. Local providers only, so nothing leaves this Mac. Off by default.", icon: "text.append") {
                        let choices: [(value: String, label: String)] = appState.providers
                            .filter { $0.isEnabled && CompactionSummarizer.isLocal($0.kind) }
                            .flatMap { provider in
                                provider.models.map {
                                    (CompactionSummarizer.settingValue(providerId: provider.id, modelId: $0.id), "\(provider.name) · \($0.name)")
                                }
                            }
                        let current = appState.settings.compactionSummarizerModel
                        Picker("", selection: $appState.settings.compactionSummarizerModel) {
                            Text("Off").tag("")
                            if !current.isEmpty, !choices.contains(where: { $0.value == current }) {
                                Text("Unavailable (\(current))").tag(current)
                            }
                            ForEach(choices, id: \.value) { choice in
                                Text(choice.label).tag(choice.value)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }

                SettingsRow(title: "Audio Notifications", subtitle: "Play chime when agents finish long tasks", icon: "speaker.wave.2") {
                    Toggle("", isOn: $appState.settings.playNotificationSounds)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Menu Bar Monitor", subtitle: "Show loaded models, memory and background runs in the menu bar, with quick actions", icon: "menubar.rectangle") {
                    Toggle("", isOn: $appState.settings.showMenuBarMonitor)
                        .toggleStyle(.switch)
                }
            }
        }
    }
}
