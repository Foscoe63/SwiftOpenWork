import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The AI Providers page.

extension SettingsView {
    var aiProvidersPage: some View {
        VStack(spacing: 16) {
            providerGroup(.local, title: "Local", description: "Servers running on this Mac or your network", icon: "desktopcomputer")
            providerGroup(.cloud, title: "Cloud", description: "Hosted model providers that need an API key", icon: "cloud.fill")
        }
        .sheet(item: $addingProviderGroup) { group in
            ProviderEditModalView(
                provider: ModelProvider(
                    name: "Custom Provider",
                    type: group,
                    kind: .custom,
                    baseUrl: group == .local ? "http://127.0.0.1:8000/v1" : ""
                ),
                appState: appState,
                isNewProvider: true
            ) { saved in
                var provider = saved
                // A provider's kind decides its group; "custom" is the one kind that can be either,
                // so it stays in the group whose Add button was used.
                provider.type = provider.kind == .custom ? group : provider.kind.type
                appState.saveProvider(provider)
                addingProviderGroup = nil
            } onCancel: {
                addingProviderGroup = nil
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditModalView(provider: provider, appState: appState, isNewProvider: false) { saved in
                var updated = saved
                updated.type = provider.type
                appState.saveProvider(updated)
                editingProvider = nil
            } onCancel: {
                editingProvider = nil
            }
        }
        .onAppear { appState.loadProviderKeysForDisplay() }
    }

    func providerGroup(_ group: ProviderType, title: String, description: String, icon: String) -> some View {
        let members = appState.providers.filter { $0.type == group }
        return SettingsCard(title: "\(title) (\(members.count))", description: description, icon: icon, collapseKey: "aiProviders.\(title.lowercased())") {
            HStack {
                Button {
                    addingProviderGroup = group
                } label: {
                    Label("Add Custom \(title) Provider", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }

            ForEach(members) { prov in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: prov.kind.icon).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prov.name).font(.system(size: 12.5, weight: .semibold))
                            Text("\(prov.baseUrl) • \(prov.models.count) models")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            editingProvider = prov
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit provider")
                    }
                    HStack(spacing: 10) {
                        // Local servers can require a key too (oMLX, LM Studio and others have an
                        // API key option). The built-in engines run in-process and take none.
                        if prov.type == .cloud || (prov.kind != .omlx && prov.kind != .vmlx && prov.kind != .splash) {
                            ProviderKeyField(provider: prov) { appState.saveProvider($0) }
                        }

                        // Local servers (Ollama, LM Studio, vMLX, oMLX) have no key, but the user
                        // may run them on another port or host, so the endpoint must be editable.
                        if prov.type == .local {
                            LocalProviderURLField(provider: prov) { appState.saveProvider($0) }
                        }

                        // Splash pins one model per process and only reports whichever one is
                        // currently resident — there's no catalog endpoint to fetch a list from, so
                        // this button never had a meaningful job for it (same reasoning as
                        // ProvidersView's splashControls / Fetch Models omission).
                        if prov.kind != .splash {
                            Button("Fetch Models") {
                                appState.refreshModels(for: prov)
                            }
                        }

                        Button("Test") {
                            Task {
                                // Splash isn't a server the user starts themselves — it's a
                                // subprocess SplashServerManager owns, so testing it means starting
                                // it (or confirming it's already running), not just GETting its
                                // base URL like every other provider. A plain testConnection()
                                // always failed here because nothing was ever listening on the port.
                                if prov.kind == .splash {
                                    let modelId = prov.models.first(where: { $0.isDefault })?.id ?? prov.models.first?.id ?? ""
                                    guard !modelId.isEmpty else {
                                        appState.showToast("\(prov.name): Add a model before testing.")
                                        return
                                    }
                                    let result = await SplashServerManager.shared.ensureRunning(modelId: modelId, baseUrl: prov.baseUrl, settings: appState.settings)
                                    appState.showToast(result.success ? "\(prov.name): Connected!" : "\(prov.name): \(result.message)")
                                } else {
                                    do {
                                        let ok = try await ProviderRouter.shared.client(for: prov).testConnection(provider: prov)
                                        appState.showToast(ok ? "\(prov.name): Connected!" : "\(prov.name): Failed")
                                    } catch {
                                        appState.showToast("\(prov.name): \(error.localizedDescription)")
                                    }
                                }
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
                .padding(.vertical, 4)
            }
        }
    }
}

/// Base URL editor for a local provider. Edits are held in a draft and saved on Return or when
/// focus leaves, so a half-typed URL is never persisted or used to probe the server.
private struct LocalProviderURLField: View {
    let provider: ModelProvider
    let onSave: (ModelProvider) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(provider: ModelProvider, onSave: @escaping (ModelProvider) -> Void) {
        self.provider = provider
        self.onSave = onSave
        self._draft = State(initialValue: provider.baseUrl)
    }

    var body: some View {
        TextField(provider.kind.defaultBaseUrl, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: provider.baseUrl) { _, new in if !focused { draft = new } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != provider.baseUrl else { draft = provider.baseUrl; return }
        var updated = provider
        updated.baseUrl = trimmed
        onSave(updated)
    }
}

/// API key editor for a provider. Saving writes to the Keychain, so edits are held in a draft and
/// saved on Return or when focus leaves, not on every keystroke.
private struct ProviderKeyField: View {
    let provider: ModelProvider
    let onSave: (ModelProvider) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(provider: ModelProvider, onSave: @escaping (ModelProvider) -> Void) {
        self.provider = provider
        self.onSave = onSave
        self._draft = State(initialValue: provider.apiKey)
    }

    var body: some View {
        SecureField("API Key", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: provider.apiKey) { _, new in if !focused { draft = new } }
    }

    private func commit() {
        guard draft != provider.apiKey else { return }
        var updated = provider
        updated.apiKey = draft
        onSave(updated)
    }
}
