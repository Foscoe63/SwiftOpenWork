import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

public enum ProvidersViewTab: String, CaseIterable, Identifiable {
    case localModels = "localModels"
    case cloudProviders = "cloudProviders"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localModels: return "Local Models (Built-in)"
        case .cloudProviders: return "Cloud & Remote Providers"
        }
    }

    public var icon: String {
        switch self {
        case .localModels: return "cube.fill"
        case .cloudProviders: return "cloud.fill"
        }
    }
}

public struct ProvidersView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: ProvidersViewTab = .localModels
    @State private var showingAddProvider = false
    @State private var editingProvider: ModelProvider? = nil
    @State private var pullModelName: String = "llama3:latest"
    @State private var fetchingProviderIds: Set<String> = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar with Tab Switcher
            headerBar

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            if selectedTab == .localModels {
                // Exact Osaurus-style Local Models View (On Device / Catalog, RAM/Storage Gauges, Model Cards)
                LocalModelsView(appState: appState)
            } else {
                // Cloud & Remote Providers View
                cloudProvidersView
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingAddProvider) {
            ProviderEditModalView(
                provider: ModelProvider(name: "OpenAI", type: .cloud, kind: .openai),
                appState: appState,
                isNewProvider: true
            ) { updated in
                appState.saveProvider(updated)
                showingAddProvider = false
            } onCancel: {
                showingAddProvider = false
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditModalView(
                provider: provider,
                appState: appState,
                isNewProvider: false
            ) { updated in
                appState.saveProvider(updated)
                editingProvider = nil
            } onCancel: {
                editingProvider = nil
            }
        }
        .onAppear { appState.loadProviderKeysForDisplay() }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Model Providers")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Text("Manage on-device Apple Silicon models and external hosted frontier providers")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            // View Tab Picker (Local Models vs Cloud Providers)
            HStack(spacing: 4) {
                ForEach(ProvidersViewTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                            Text(tab.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            if tab == .localModels {
                                let count = appState.localMLXModels.filter { $0.isDownloaded }.count
                                Text("(\(count))")
                                    .font(.system(size: 11))
                                    .opacity(0.8)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : Color.clear)
                        )
                        .foregroundColor(isSelected ? .white : ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.hitTestable)
                }
            }
            .padding(3)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
            )

            if selectedTab == .cloudProviders {
                Button {
                    showingAddProvider = true
                } label: {
                    Label("Add Provider", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeColors.accent(for: appState.settings.accentColor))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Cloud & Remote Providers View
    private var cloudProvidersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Built-in Local Provider Highlight Card
                builtinProviderHighlightCard

                // Ollama Quick Pull Box
                ollamaPullCard

                // Local Endpoints (Ollama, LM Studio)
                sectionHeader(title: "LOCAL DAEMONS & SERVERS", subtitle: "Ollama, LM Studio, and localhost inference endpoints")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 14)], spacing: 14) {
                    ForEach(appState.providers.filter { $0.type == .local && $0.kind != .omlx && $0.kind != .vmlx }) { provider in
                        providerCard(provider: provider)
                    }
                }

                // Cloud Providers Section
                sectionHeader(title: "CLOUD MODEL PROVIDERS", subtitle: "Connect state-of-the-art hosted frontier models")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 460), spacing: 14)], spacing: 14) {
                    ForEach(appState.providers.filter { $0.type == .cloud }) { provider in
                        providerCard(provider: provider)
                    }
                }
            }
            .padding(18)
        }
    }

    // MARK: - Built-in Provider Highlight Card
    private var builtinProviderHighlightCard: some View {
        let downloadedCount = appState.localMLXModels.filter { $0.isDownloaded }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "#C084FC"))

                        Text("Built-in (Apple Silicon MLX)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        Text("BUILT-IN ENGINE")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#C084FC").opacity(0.2))
                            .foregroundColor(Color(hex: "#C084FC"))
                            .cornerRadius(4)
                    }

                    Text("Zero-latency, 100% private native Metal shader inference with direct unified memory access.")
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                Spacer()

                Button {
                    withAnimation {
                        selectedTab = .localModels
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Open Local Models (\(downloadedCount))")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(ThemeColors.accent(for: appState.settings.accentColor))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.hitTestable)
            }

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.6))

            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    Text("Hardware RAM: \(String(format: "%.0f GB", LocalMLXEngine.physicalRAMGB))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }

                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    Text("GPU Safe Budget: \(String(format: "%.0f GB", LocalMLXEngine.physicalRAMGB * appState.settings.mlxGpuMemoryBudgetRatio))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                }

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("\(downloadedCount) models installed on-device")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "#12111A"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#A855F7").opacity(0.3), lineWidth: 1.5)
        )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
        }
    }

    // MARK: - Ollama Quick Pull Box
    private var ollamaPullCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                Text("Download / Pull Local Ollama Model")
                    .font(.system(size: 13, weight: .bold))
            }

            Text("Enter any HuggingFace or Ollama library tag (e.g. `llama3.3:70b`, `deepseek-r1:14b`, `qwen2.5-coder:32b`) to download it directly to your Mac.")
                .font(.system(size: 11.5))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

            HStack(spacing: 8) {
                TextField("Model Tag (e.g. qwen2.5-coder:32b)", text: $pullModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button {
                    appState.pullOllamaModel(name: pullModelName)
                } label: {
                    HStack(spacing: 4) {
                        if appState.isPullingModel {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.down.to.line.compact")
                        }
                        Text(appState.isPullingModel ? "Pulling..." : "Pull Model")
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeColors.accent(for: appState.settings.accentColor))
                .disabled(pullModelName.trimmingCharacters(in: .whitespaces).isEmpty || appState.isPullingModel)
            }

            if appState.isPullingModel {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: appState.pullModelProgress)
                    Text(appState.pullModelStatusText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
    }

    // MARK: - Provider Card
    private func providerCard(provider: ModelProvider) -> some View {
        let isCurrentProvider = appState.selectedProviderId == provider.id
        let isFetching = fetchingProviderIds.contains(provider.id)

        return VStack(alignment: .leading, spacing: 12) {
            // Top Row: Icon, Name, Type Badge, Enabled Switch
            HStack(spacing: 10) {
                Image(systemName: provider.kind.icon)
                    .font(.system(size: 18))
                    .foregroundColor(provider.isEnabled ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        if isCurrentProvider {
                            Text("ACTIVE")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(3)
                        }
                    }

                    Text(provider.baseUrl)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { val in
                        var updated = provider
                        updated.isEnabled = val
                        appState.saveProvider(updated)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme).opacity(0.5))

            // Model Selection Dropdown Box
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Selected Model:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    Spacer()
                    Text("\(provider.models.count) available")
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.8))
                }

                if provider.models.isEmpty {
                    Text("No models discovered. Click 'Fetch Models' to load catalog.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                } else {
                    let activeModelId = isCurrentProvider ? appState.selectedModelId : (provider.models.first(where: { $0.isDefault })?.id ?? provider.models.first?.id ?? "")
                    
                    Menu {
                        ForEach(provider.models) { m in
                            Button {
                                appState.selectedProviderId = provider.id
                                appState.selectedModelId = m.id
                                appState.showToast("Selected \(m.name) for \(provider.name)")
                            } label: {
                                HStack {
                                    Text(m.name)
                                    if m.supportsReasoning {
                                        Text("🧠 Reasoning")
                                    }
                                    if m.id == activeModelId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            let selectedModel = provider.models.first(where: { $0.id == activeModelId }) ?? provider.models.first
                            Text(selectedModel?.name ?? "Select Model")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                .lineLimit(1)
                            
                            if selectedModel?.supportsReasoning == true {
                                Text("🧠")
                                    .font(.system(size: 10))
                            }
                            
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ThemeColors.bg(for: appState.settings.theme))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            // Actions Row: Fetch Models & Configure
            HStack(spacing: 8) {
                Button {
                    fetchModelsForProvider(provider)
                } label: {
                    HStack(spacing: 4) {
                        if isFetching {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(isFetching ? "Fetching..." : "Fetch Models")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetching)

                Button("Test Ping") {
                    Task {
                        let ok = (try? await ProviderRouter.shared.client(for: provider).testConnection(provider: provider)) ?? false
                        appState.showToast(ok ? "\(provider.name): Connected!" : "\(provider.name): Connection Failed")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    editingProvider = provider
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .buttonStyle(.hitTestable)
                .help("Edit Provider Settings")

                if appState.providers.count > 1 {
                    Button {
                        appState.deleteProvider(provider)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.hitTestable)
                    .help("Delete Provider")
                }
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrentProvider ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.6) : ThemeColors.border(for: appState.settings.theme), lineWidth: isCurrentProvider ? 1.5 : 1)
        )
    }

    private func fetchModelsForProvider(_ provider: ModelProvider) {
        fetchingProviderIds.insert(provider.id)
        Task {
            do {
                let client = ProviderRouter.shared.client(for: provider)
                let fetchedModels = try await client.listModels(provider: provider)
                await MainActor.run {
                    var updated = provider
                    updated.models = fetchedModels
                    appState.saveProvider(updated)
                    fetchingProviderIds.remove(provider.id)
                    appState.showToast("Loaded \(fetchedModels.count) models for \(provider.name)")
                }
            } catch {
                await MainActor.run {
                    fetchingProviderIds.remove(provider.id)
                    appState.showToast("Error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Provider Edit Modal View
public struct ProviderEditModalView: View {
    let provider: ModelProvider
    @ObservedObject var appState: AppState
    let isNewProvider: Bool
    let onSave: (ModelProvider) -> Void
    let onCancel: () -> Void

    @State private var draft: ModelProvider
    @State private var selectedModelId: String = ""
    @State private var newModelId: String = ""
    @State private var newModelName: String = ""
    @State private var newModelContext: String = "128000"
    @State private var isFetchingModels = false

    public init(
        provider: ModelProvider,
        appState: AppState,
        isNewProvider: Bool,
        onSave: @escaping (ModelProvider) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.appState = appState
        self.isNewProvider = isNewProvider
        self.onSave = onSave
        self.onCancel = onCancel
        self._draft = State(initialValue: provider)
        let initialModel = provider.models.first(where: { $0.isDefault })?.id ?? provider.models.first?.id ?? ""
        self._selectedModelId = State(initialValue: initialModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Modal Header
            HStack {
                Text(isNewProvider ? "Add Model Provider" : "Edit Provider: \(draft.name)")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.hitTestable)
            }
            .padding(16)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Preset Kind Picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider Kind & Protocol")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $draft.kind) {
                            ForEach(ProviderKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: draft.kind) { _, newKind in
                            draft.baseUrl = newKind.defaultBaseUrl
                            draft.name = newKind.displayName
                        }
                    }

                    // Display Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider Name")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Base URL
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL (API Endpoint)")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("https://api.openai.com/v1", text: $draft.baseUrl)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    // API Key
                    if draft.kind != .ollama && draft.kind != .omlx && draft.kind != .vmlx {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API Key / Bearer Token")
                                .font(.system(size: 11.5, weight: .semibold))
                            SecureField("sk-...", text: $draft.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    Divider()

                    // Models Inventory Section
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Configured Models (\(draft.models.count))")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            Button {
                                fetchRemoteModels()
                            } label: {
                                HStack(spacing: 4) {
                                    if isFetchingModels {
                                        ProgressView().scaleEffect(0.5)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    Text(isFetchingModels ? "Fetching..." : "Fetch Available")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isFetchingModels)
                        }

                        // Model List
                        ForEach(draft.models) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .font(.system(size: 12, weight: .medium))
                                        if model.isDefault {
                                            Text("DEFAULT")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundColor(.green)
                                        }
                                    }
                                    Text("\(model.id) • \(model.contextWindow / 1000)k context")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button("Set Default") {
                                    for i in 0..<draft.models.count {
                                        draft.models[i].isDefault = (draft.models[i].id == model.id)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))

                                Button {
                                    draft.models.removeAll(where: { $0.id == model.id })
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(.red.opacity(0.8))
                                }
                                .buttonStyle(.hitTestable)
                            }
                            .padding(8)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(6)
                        }

                        // Add Custom Model Row
                        HStack(spacing: 6) {
                            TextField("Model ID (e.g. gpt-6-sol)", text: $newModelId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            TextField("Display Name", text: $newModelName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button("Add") {
                                if !newModelId.isEmpty {
                                    let name = newModelName.isEmpty ? newModelId : newModelName
                                    let newModel = ModelInfo(
                                        id: newModelId,
                                        name: name,
                                        providerId: draft.id,
                                        contextWindow: Int(newModelContext) ?? 128000
                                    )
                                    draft.models.append(newModel)
                                    newModelId = ""
                                    newModelName = ""
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(newModelId.isEmpty)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer Save Action
            HStack {
                Spacer()
                Button("Save Provider") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeColors.accent(for: appState.settings.accentColor))
            }
            .padding(14)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))
        }
        .frame(width: 520, height: 560)
    }

    private func fetchRemoteModels() {
        isFetchingModels = true
        Task {
            do {
                let client = ProviderRouter.shared.client(for: draft)
                let models = try await client.listModels(provider: draft)
                await MainActor.run {
                    draft.models = models
                    isFetchingModels = false
                    appState.showToast("Discovered \(models.count) models")
                }
            } catch {
                await MainActor.run {
                    isFetchingModels = false
                    appState.showToast("Fetch failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
