import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

/// Presentation Tab for Local Models View matching Osaurus.
public enum LocalModelsTab: String, CaseIterable, Identifiable {
    case onDevice = "onDevice"
    case catalog = "catalog"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice: return "On Device"
        case .catalog: return "Catalog"
        }
    }
}

/// Sort options for the model list matching Osaurus.
public enum LocalModelSortOption: String, CaseIterable, Identifiable {
    case recommended = "recommended"
    case downloadsDesc = "downloadsDesc"
    case nameAsc = "nameAsc"
    case compatibility = "compatibility"
    case sizeAsc = "sizeAsc"
    case sizeDesc = "sizeDesc"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .recommended: return "Recommended"
        case .downloadsDesc: return "Most Downloaded"
        case .nameAsc: return "Name (A–Z)"
        case .compatibility: return "Compatibility"
        case .sizeAsc: return "Size (Smallest first)"
        case .sizeDesc: return "Size (Largest first)"
        }
    }

    public var iconName: String {
        switch self {
        case .recommended: return "sparkles"
        case .downloadsDesc: return "arrow.down.app"
        case .nameAsc: return "textformat"
        case .compatibility: return "checkmark.seal"
        case .sizeAsc: return "arrow.up.circle"
        case .sizeDesc: return "arrow.down.circle"
        }
    }
}

/// Filter options for model types and parameters.
public enum LocalModelTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case llmOnly = "LLM"
    case vlmOnly = "VLM"

    public var id: String { rawValue }
}

/// A dedicated pixel-perfect Local Models View matching Osaurus.
public struct LocalModelsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: LocalModelsTab = .onDevice
    @State private var searchText: String = ""
    @State private var sortOption: LocalModelSortOption = .recommended
    @State private var typeFilter: LocalModelTypeFilter = .all
    @State private var showingImportModal: Bool = false
    @State private var importRepoId: String = ""
    @State private var showingSearchRoots: Bool = false
    /// Which precision the user picked for a model, by group. Absent means the recommended one.
    @State private var chosenVariant: [String: String] = [:]
    /// Other precisions found on the Hub, by group. Only filled when the user asks.
    @State private var discoveredVariants: [String: [LocalMLXModel]] = [:]
    @State private var findingVariants: Set<String> = []

    public init(appState: AppState) {
        self.appState = appState
    }

    private var downloadedModels: [LocalMLXModel] {
        appState.localMLXModels.filter { $0.isDownloaded }
    }

    private var catalogModels: [LocalMLXModel] {
        appState.localMLXModels.filter { !$0.isDownloaded }
    }

    private var activeModelsList: [LocalMLXModel] {
        let base = selectedTab == .onDevice ? downloadedModels : catalogModels
        return filterAndSort(models: base)
    }

    /// One card per model, showing one precision and offering the rest as chips.
    struct Card {
        let key: String
        let model: LocalMLXModel
        let variants: [LocalMLXModel]
    }

    private var displayedCards: [Card] {
        let ratio = appState.settings.mlxGpuMemoryBudgetRatio
        let available = LocalMLXEngine.freeRAMGB
        let physical = LocalMLXEngine.physicalRAMGB
        return LocalMLXModel.variantGroups(activeModelsList).map { group in
            let key = group.first.map { $0.variantGroupKey.isEmpty ? $0.id : $0.variantGroupKey } ?? ""
            // Hub results only extend the catalog: on-device, a variant that is not downloaded is
            // not a thing you can run.
            let known = Set(group.map(\.id))
            let extra = selectedTab == .catalog ? (discoveredVariants[key] ?? []).filter { !known.contains($0.id) } : []
            let all = LocalMLXModel.variantGroups(group + extra).first ?? group
            let shown = chosenVariant[key].flatMap { id in all.first { $0.id == id } }
                ?? LocalMLXModel.recommendedVariant(in: all, budgetRatio: ratio, availableGB: available, physicalGB: physical)
                ?? all[0]
            return Card(key: key, model: shown.judged(atBudgetRatio: ratio), variants: all)
        }
    }

    private func findVariants(for card: Card) {
        guard !findingVariants.contains(card.key) else { return }
        findingVariants.insert(card.key)
        Task {
            do {
                let found = try await MLXVariantFinder.find(siblingsOf: card.model)
                discoveredVariants[card.key] = found
                if found.isEmpty { appState.showToast("No other precisions of \(card.model.name) found on Hugging Face") }
            } catch {
                appState.showToast("Could not reach Hugging Face: \(error.localizedDescription)")
            }
            findingVariants.remove(card.key)
        }
    }

    private var totalDownloadedBytes: Int64 {
        downloadedModels.compactMap { $0.sizeBytes }.reduce(0, +)
    }

    private var formattedTotalDownloadedSize: String {
        let gb = Double(totalDownloadedBytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(totalDownloadedBytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            headerView

            Divider()
                .background(Color(hex: "#242234"))

            // System Hardware Status Bar (RAM & Storage)
            systemStatusBar

            Divider()
                .background(Color(hex: "#242234"))

            // Search, Sort, Filter Toolbar
            toolbarView

            // Main Scrollable Grid (4 Columns as in Osaurus)
            ScrollView {
                if activeModelsList.isEmpty {
                    emptyStateView
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(displayedCards, id: \.key) { card in
                            LocalModelCardView(
                                model: card.model,
                                isSelected: appState.selectedModelId == card.model.id,
                                appState: appState,
                                variants: card.variants,
                                headroomGB: LocalMLXEngine.freeRAMGB,
                                isFindingVariants: findingVariants.contains(card.key),
                                onSelectVariant: { chosenVariant[card.key] = $0.id },
                                onFindVariants: selectedTab == .catalog ? { findVariants(for: card) } : nil
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(hex: "#0C0B14"))
        .onAppear {
            appState.refreshLoadedMLXModels()
        }
        .sheet(isPresented: $showingImportModal) {
            importModelModal
        }
    }

    // MARK: - Header View
    private var headerView: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Models")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("\(downloadedModels.count) downloaded • \(formattedTotalDownloadedSize)"
                         + (appState.loadedMLXModelIds.isEmpty
                            ? ""
                            : " • \(appState.loadedMLXModelIds.count) loaded in memory"))
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.65))
                }

                Spacer()

                HStack(spacing: 10) {
                    if !appState.loadedMLXModelIds.isEmpty {
                        Button {
                            appState.unloadAllMLXModels()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "memorychip")
                                    .font(.system(size: 12))
                                Text("Unload All")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(Color.orange)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.hitTestable)
                        .help("Free Metal/RAM used by in-process MLX models so you can load a different one")
                    }

                    // Rescan button
                    Button {
                        appState.rescanMLXModels()
                    } label: {
                        HStack(spacing: 6) {
                            if appState.isScanningMLX {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            Text("Rescan")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(hex: "#181726"))
                        .foregroundColor(Color.white.opacity(0.85))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(hex: "#2E2C44"), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.hitTestable)
                    .disabled(appState.isScanningMLX)

                    // 🤗 Import Button
                    Button {
                        showingImportModal = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("🤗")
                                .font(.system(size: 13))
                            Text("Import")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "#181726"))
                        .foregroundColor(Color.white.opacity(0.9))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(hex: "#2E2C44"), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.hitTestable)
                }
            }

            // Tabs Selector
            HStack {
                HStack(spacing: 4) {
                    tabPill(
                        tab: .onDevice,
                        title: "On Device",
                        count: downloadedModels.count
                    )
                    tabPill(
                        tab: .catalog,
                        title: "Catalog",
                        count: catalogModels.count
                    )
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "#161524"))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "#2A2740"), lineWidth: 1)
                )

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(Color(hex: "#0F0E1A"))
    }

    private func tabPill(tab: LocalModelsTab, title: String, count: Int) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))

                Text("(\(count))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : Color.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(hex: "#26153B") : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color(hex: "#A855F7") : Color.clear, lineWidth: 1.2)
            )
            .shadow(color: isSelected ? Color(hex: "#A855F7").opacity(0.4) : Color.clear, radius: 4)
        }
        .buttonStyle(.hitTestable)
    }

    // MARK: - System Hardware Status Bar
    private var systemStatusBar: some View {
        HStack(spacing: 28) {
            // RAM Gauge
            let totalRAM = LocalMLXEngine.physicalRAMGB
            let freeRAM = LocalMLXEngine.freeRAMGB
            let usedRAM = max(0, totalRAM - freeRAM)
            let ramFraction = totalRAM > 0 ? (usedRAM / totalRAM) : 0

            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.6))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("RAM")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.6))
                        Spacer()
                        Text(String(format: "%.0f GB free / %.0f GB", freeRAM, totalRAM))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "#34D399"))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "#34D399"))
                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.05, 1.0 - ramFraction))))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .frame(maxWidth: .infinity)

            // Storage Gauge
            let totalStorage = LocalMLXEngine.totalStorageGB
            let freeStorage = LocalMLXEngine.freeStorageGB
            let usedStorage = max(0, totalStorage - freeStorage)
            let storageFraction = totalStorage > 0 ? (usedStorage / totalStorage) : 0

            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.6))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("Storage")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.6))
                        Spacer()
                        Text(formatStorageDetail(free: freeStorage, total: totalStorage))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "#34D399"))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "#34D399"))
                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.05, 1.0 - storageFraction))))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(hex: "#100F1C"))
    }

    private func formatStorageDetail(free: Double, total: Double) -> String {
        let freeStr = free >= 1000 ? String(format: "%.1f TB", free / 1000) : String(format: "%.0f GB", free)
        let totalStr = total >= 1000 ? String(format: "%.1f TB", total / 1000) : String(format: "%.0f GB", total)
        return "\(freeStr) free / \(totalStr)"
    }

    // MARK: - Toolbar View (Search, Sort, Filter)
    private var toolbarView: some View {
        HStack(spacing: 12) {
            // Search Input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.45))

                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.45))
                    }
                    .buttonStyle(.hitTestable)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(hex: "#151422"))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#28263C"), lineWidth: 1)
            )
            .frame(maxWidth: 280)

            Spacer()

            // Sort Menu
            Menu {
                ForEach(LocalModelSortOption.allCases) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        HStack {
                            Image(systemName: opt.iconName)
                            Text(opt.displayName)
                            if sortOption == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                    Text("Sort")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "#151422"))
                .foregroundColor(Color.white.opacity(0.85))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#28263C"), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Where the scan looked. This lived only under Settings › Debug behind developer mode,
            // while this view is where someone whose models are missing actually looks.
            Button {
                showingSearchRoots = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Folders")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "#151422"))
                .foregroundColor(Color.white.opacity(0.85))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#28263C"), lineWidth: 1)
                )
            }
            .buttonStyle(.hitTestable)
            .fixedSize()
            .help("Show every folder scanned for model weights")
            .popover(isPresented: $showingSearchRoots, arrowEdge: .bottom) {
                SearchRootsPopover(appState: appState)
            }

            // Filter Menu
            Menu {
                Section("Model Type") {
                    ForEach(LocalModelTypeFilter.allCases) { f in
                        Button {
                            typeFilter = f
                        } label: {
                            HStack {
                                Text(f.rawValue)
                                if typeFilter == f {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                    Text("Filter")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "#151422"))
                .foregroundColor(Color.white.opacity(0.85))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#28263C"), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: - Filtering & Sorting Logic
    private func filterAndSort(models: [LocalMLXModel]) -> [LocalMLXModel] {
        var result = models

        // Text Search
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                $0.description.lowercased().contains(query) ||
                $0.tags.contains(where: { $0.lowercased().contains(query) })
            }
        }

        // Type filter
        switch typeFilter {
        case .all: break
        case .llmOnly: result = result.filter { !$0.isVLM }
        case .vlmOnly: result = result.filter { $0.isVLM }
        }

        // Sort
        switch sortOption {
        case .recommended:
            result.sort { ($0.isTopPick ? 0 : 1) < ($1.isTopPick ? 0 : 1) }
        case .downloadsDesc:
            result.sort { ($0.downloadCount ?? 0) > ($1.downloadCount ?? 0) }
        case .nameAsc:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .compatibility:
            result.sort { ($0.compatibility == .runsWell ? 0 : 1) < ($1.compatibility == .runsWell ? 0 : 1) }
        case .sizeAsc:
            result.sort { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
        case .sizeDesc:
            result.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }

        return result
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedTab == .onDevice ? "externaldrive.badge.xmark" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(Color.white.opacity(0.4))
                .padding(.top, 60)

            Text(selectedTab == .onDevice ? "No Models Downloaded Yet" : "No Models Found")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Text(selectedTab == .onDevice ? "Switch to the Catalog tab to download Apple Silicon MLX models, or use Folders above to point at a library you already have." : "Try adjusting your search query or filter options.")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if selectedTab == .onDevice {
                Button("Browse Catalog") {
                    selectedTab = .catalog
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Import Model Modal
    private var importModelModal: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Import Local / Hugging Face Model")
                    .font(.headline)
                Spacer()
                Button {
                    showingImportModal = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("1. Import via Hugging Face Repo ID")
                    .font(.system(size: 12, weight: .semibold))

                HStack(spacing: 8) {
                    TextField("e.g. mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", text: $importRepoId)
                        .textFieldStyle(.roundedBorder)

                    Button("Download") {
                        if !importRepoId.isEmpty {
                            let dummy = LocalMLXModel(
                                id: importRepoId,
                                name: importRepoId.split(separator: "/").last.map(String.init) ?? importRepoId,
                                description: "Imported Hugging Face MLX model."
                            )
                            appState.pullMLXModel(dummy)
                            showingImportModal = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importRepoId.isEmpty)
                }

                Divider().padding(.vertical, 4)

                Text("2. Link Existing Model Directory on Disk")
                    .font(.system(size: 12, weight: .semibold))

                Text("Select an MLX model directory containing config.json and .safetensors/.mlx files.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        appState.settings.customMLXModelsDirectory = url.path
                        appState.updateSettings(appState.settings)
                        appState.rescanMLXModels()
                        showingImportModal = false
                        appState.showToast("Imported folder '\(url.lastPathComponent)'")
                    }
                } label: {
                    Label("Choose Folder...", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Local Model Card View (Matching Osaurus Screenshot)
public struct LocalModelCardView: View {
    let model: LocalMLXModel
    let isSelected: Bool
    @ObservedObject var appState: AppState
    /// Every precision of this model the card can switch between. One entry means no chips.
    var variants: [LocalMLXModel] = []
    /// Free memory right now, for the fit verdict.
    var headroomGB: Double = LocalMLXEngine.freeRAMGB
    var isFindingVariants = false
    var onSelectVariant: (LocalMLXModel) -> Void = { _ in }
    var onFindVariants: (() -> Void)?
    @State private var isHovering: Bool = false
    @State private var confirmingMisfit = false

    private var fit: MLXMemoryFit {
        MLXMemoryBudget.fit(
            requiredRAMGB: model.estimatedRAMGB,
            budgetRatio: appState.settings.mlxGpuMemoryBudgetRatio,
            availableGB: headroomGB,
            physicalGB: LocalMLXEngine.physicalRAMGB
        )
    }

    private func color(for fit: MLXMemoryFit) -> Color {
        switch fit {
        case .fits: return Color(hex: "#34D399")
        case .needsFreeMemory, .overBudget: return Color(hex: "#FBBF24")
        case .wontLoad: return Color(hex: "#F87171")
        }
    }


    public var body: some View {
        VStack(spacing: 0) {
            // Gradient Header (matching Osaurus family colors)
            ZStack {
                LinearGradient(
                    colors: gradientColors(for: model),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Dark radial vignette bottom-right
                RadialGradient(
                    colors: [.black.opacity(0.35), .clear],
                    center: UnitPoint(x: 0.9, y: 0.9),
                    startRadius: 8,
                    endRadius: 200
                )

                // Top Badges Row
                VStack {
                    HStack {
                        if model.isDownloaded {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9.5))
                                Text("Downloaded")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.22))
                            .clipShape(Capsule())
                        } else {
                            Text("Available")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.3))
                                .clipShape(Capsule())
                        }

                        if appState.loadedMLXModelIds.contains(model.id) {
                            HStack(spacing: 4) {
                                Image(systemName: "memorychip")
                                    .font(.system(size: 9.5))
                                Text("In Memory")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.55))
                            .clipShape(Capsule())
                        }

                        Spacer()

                        if model.isTopPick {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                                .padding(4)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Circle())
                        }
                    }
                    Spacer()
                }
                .padding(10)

                // Model Title Centered with soft drop shadow
                Text(model.name)
                    .font(.system(size: 16.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1.5)
                    .padding(.horizontal, 14)
            }
            .frame(height: 130)

            // Card Bottom Body
            VStack(alignment: .leading, spacing: 10) {
                // Tags Row (LLM/VLM + Compatibility)
                HStack(spacing: 6) {
                    // Type Badge
                    HStack(spacing: 3) {
                        Image(systemName: model.isVLM ? "eye.fill" : "bubble.left.fill")
                            .font(.system(size: 8.5))
                        Text(model.isVLM ? "VLM" : "LLM")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundColor(Color(hex: "#C084FC"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color(hex: "#C084FC").opacity(0.18))
                    .cornerRadius(4)

                    // Compatibility Badge
                    HStack(spacing: 3) {
                        Image(systemName: model.compatibility == .runsWell ? "checkmark.shield.fill" : (model.compatibility == .tight ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                            .font(.system(size: 8.5))
                        Text(model.compatibility.displayName)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundColor(model.compatibility == .runsWell ? Color(hex: "#34D399") : (model.compatibility == .tight ? Color(hex: "#FBBF24") : Color(hex: "#F87171")))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        (model.compatibility == .runsWell ? Color(hex: "#34D399") : (model.compatibility == .tight ? Color(hex: "#FBBF24") : Color(hex: "#F87171"))).opacity(0.18)
                    )
                    .cornerRadius(4)

                    Spacer()
                }

                // 3-Column Stat Strip (Matching Osaurus style)
                HStack(spacing: 0) {
                    statColumn(title: "DOWNLOAD", value: model.formattedSize)
                    divider
                    statColumn(title: "EST. MEMORY", value: model.formattedRAM)
                    divider
                    statColumn(title: "PARAMS", value: model.parameterCount ?? "—")
                }
                .padding(.vertical, 7)
                .background(Color(hex: "#1A1828"))
                .cornerRadius(6)

                precisionChips

                if fit != .fits, !(model.isDownloaded && loadedHere) {
                    HStack(spacing: 5) {
                        Image(systemName: fit.willLikelyFail ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        Text(fitDetail)
                            .lineLimit(2)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(color(for: fit))
                }

                // Footer Line
                Text(model.isDownloaded ? "Local model (detected)" : model.description)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.6))
                    .lineLimit(1)

                // Card Actions
                HStack(spacing: 8) {
                    if model.isDownloaded {
                        Button {
                            if fit.willLikelyFail { confirmingMisfit = true } else { appState.selectLocalMLXModel(model) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "bolt.fill")
                                    .font(.system(size: 10))
                                Text(isSelected ? "Active Model" : "Select Model")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5.5)
                            .background(isSelected ? Color(hex: "#059669") : Color(hex: "#9333EA").opacity(0.3))
                            .foregroundColor(isSelected ? .white : Color(hex: "#D8B4FE"))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        if appState.loadedMLXModelIds.contains(model.id) {
                            Button {
                                appState.unloadMLXModel(id: model.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "eject.fill")
                                        .font(.system(size: 10))
                                    Text("Unload")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(Color.orange.opacity(0.22))
                                .foregroundColor(Color.orange)
                                .cornerRadius(5)
                            }
                            .buttonStyle(.hitTestable)
                            .help("Unload this model from Metal/RAM")
                        }

                        Button {
                            do {
                                if appState.loadedMLXModelIds.contains(model.id) {
                                    appState.unloadMLXModel(id: model.id)
                                }
                                try LocalMLXEngine.shared.deleteModel(model: model)
                                appState.rescanMLXModels()
                                appState.showToast("Removed \(model.name)")
                            } catch {
                                appState.showToast("Could not delete: \(error.localizedDescription)")
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.8))
                                .padding(5.5)
                                .background(Color.red.opacity(0.12))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.hitTestable)
                    } else {
                        Button {
                            if fit.willLikelyFail { confirmingMisfit = true } else { appState.pullMLXModel(model) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 10))
                                Text("Download (\(model.formattedSize))")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5.5)
                            .background(Color(hex: "#9333EA"))
                            .foregroundColor(.white)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
        .background(Color(hex: "#12111E"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isHovering ? Color(hex: "#C026D3").opacity(0.8) : Color(hex: "#9333EA").opacity(0.25),
                    lineWidth: 1.5
                )
        )
        .shadow(
            color: Color(hex: "#9333EA").opacity(isHovering ? 0.35 : 0.12),
            radius: isHovering ? 14 : 6,
            x: 0,
            y: 4
        )
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = h
            }
        }
        .alert("\(model.name) won't fit on this Mac", isPresented: $confirmingMisfit) {
            Button("Cancel", role: .cancel) {}
            Button(model.isDownloaded ? "Load Anyway" : "Download Anyway", role: .destructive) {
                if model.isDownloaded { appState.selectLocalMLXModel(model) } else { appState.pullMLXModel(model) }
            }
        } message: {
            Text(fitDetail + (model.isDownloaded ? " Loading it is likely to fail or make the Mac unresponsive." : " It would download, but could not be loaded."))
        }
    }

    private var loadedHere: Bool { appState.loadedMLXModelIds.contains(model.id) }

    private var fitDetail: String {
        let need = String(format: "%.0f", model.estimatedRAMGB)
        let free = String(format: "%.0f", headroomGB)
        let total = String(format: "%.0f", LocalMLXEngine.physicalRAMGB)
        switch fit {
        case .fits: return ""
        case .needsFreeMemory(let short):
            return "Needs ~\(need) GB; \(free) GB is free now. Close apps or unload a model to free \(String(format: "%.0f", max(1, short.rounded(.up)))) GB."
        case .overBudget:
            return "Needs ~\(need) GB, above your GPU memory budget. Raise it in Settings or pick a smaller precision."
        case .wontLoad:
            return "Needs ~\(need) GB; this Mac has \(total) GB. Pick a smaller precision."
        }
    }

    /// The precisions this model comes in, each marked by whether it fits in memory right now.
    @ViewBuilder
    private var precisionChips: some View {
        if variants.count > 1 || onFindVariants != nil {
            HStack(spacing: 5) {
                ForEach(variants) { variant in
                    let verdict = MLXMemoryBudget.fit(
                        requiredRAMGB: variant.estimatedRAMGB,
                        budgetRatio: appState.settings.mlxGpuMemoryBudgetRatio,
                        availableGB: headroomGB,
                        physicalGB: LocalMLXEngine.physicalRAMGB
                    )
                    Button {
                        onSelectVariant(variant)
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(color(for: verdict)).frame(width: 5, height: 5)
                            Text(variant.quantization ?? "?")
                            Text(String(format: "%.0f GB", variant.estimatedRAMGB))
                                .foregroundColor(Color.white.opacity(0.5))
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(variant.id == model.id ? Color(hex: "#9333EA").opacity(0.45) : Color.white.opacity(0.07))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("\(variant.name): \(verdict.label)")
                }
                if let onFindVariants {
                    Button {
                        onFindVariants()
                    } label: {
                        if isFindingVariants {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("More…").font(.system(size: 9.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(hex: "#C084FC"))
                    .help("Look up other precisions of this model on Hugging Face")
                    .disabled(isFindingVariants)
                }
                Spacer()
            }
        }
    }

    private func statColumn(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 20)
    }

    /// Curated vivid gradients matching Osaurus screenshot.
    private func gradientColors(for model: LocalMLXModel) -> [Color] {
        let name = model.name.lowercased()
        let id = model.id.lowercased()

        if name.contains("ornith") || id.contains("ornith") {
            // Dark Rose / Crimson to Deep Magenta
            return [Color(hex: "#E11D48"), Color(hex: "#881337")]
        } else if name.contains("qwen3 coder next") || id.contains("qwen3-coder-next") {
            // Bright Electric Blue / Cyan
            return [Color(hex: "#0EA5E9"), Color(hex: "#0284C7")]
        } else if name.contains("qwen") || id.contains("qwen") {
            // Bright Electric Cyan / Teal
            return [Color(hex: "#06B6D4"), Color(hex: "#0369A1")]
        } else if name.contains("gemma") || id.contains("gemma") {
            // Indigo to Deep Blue
            return [Color(hex: "#6366F1"), Color(hex: "#1D4ED8")]
        } else if name.contains("llama") || id.contains("llama") {
            // Violet to Purple
            return [Color(hex: "#8B5CF6"), Color(hex: "#A21CAF")]
        } else if name.contains("deepseek") || id.contains("deepseek") {
            // Cobalt Blue to Deep Indigo
            return [Color(hex: "#2563EB"), Color(hex: "#4338CA")]
        } else if name.contains("mistral") || id.contains("mistral") || name.contains("codestral") {
            // Orange to Crimson
            return [Color(hex: "#F97316"), Color(hex: "#DC2626")]
        } else {
            return [Color(hex: "#06B6D4"), Color(hex: "#4338CA")]
        }
    }
}

/// Every folder the model scan looks in, with a way to add one.
private struct SearchRootsPopover: View {
    @ObservedObject var appState: AppState
    @State private var searchRoots: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folders scanned for models")
                .font(.system(size: 13, weight: .semibold))
            Text("Only folders that exist are listed. A model elsewhere will not be found until its folder is added.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(searchRoots, id: \.self) { root in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(root.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Button("Add Models Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.prompt = "Use Folder"
                    if panel.runModal() == .OK, let url = panel.url {
                        appState.settings.customMLXModelsDirectory = url.path
                        appState.updateSettings(appState.settings)
                        appState.rescanMLXModels()
                        reload()
                    }
                }
                .help("Sets the custom models directory, replacing any previous one")
                Spacer()
                Button("Rescan") {
                    appState.rescanMLXModels()
                }
                .disabled(appState.isScanningMLX)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 460)
        // Read when the popover opens, not when the button is pressed: popover content is hosted
        // in its own window and did not see state the button set in the same action, so the
        // list rendered empty.
        .onAppear { reload() }
    }

    private func reload() {
        searchRoots = LocalMLXEngine.knownMLXSearchRoots(settings: appState.settings)
    }
}
