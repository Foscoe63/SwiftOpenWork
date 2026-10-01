import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkLocalInference

/// The menu bar popover: what is loaded, how much memory is left, what is running without a
/// window, and the few actions worth reaching without switching to the app.
struct MenuBarMonitorView: View {
    @ObservedObject var appState: AppState

    private var loadedModels: [(id: String, name: String, ramGB: Double?)] {
        appState.loadedMLXModelIds.map { id in
            let model = appState.localMLXModels.first { $0.id == id }
            return (id, model?.name ?? id, model?.estimatedRAMGB)
        }
    }

    private var runningLoops: [AgentLoop] { appState.loops.filter { $0.state == .running } }
    private var scheduledLoops: Int { appState.loops.filter { $0.everyMinutes != nil && $0.scheduleOffReason == nil }.count }
    private var enabledAutomations: Int { appState.automations.filter(\.isEnabled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(BackgroundRun.statusLine(chatIsGenerating: appState.isGenerating, runs: appState.backgroundRuns))
                .font(.system(size: 12.5, weight: .semibold))

            // Re-read on a timer: free memory changes whether or not anything in the app does.
            TimelineView(.periodic(from: .now, by: 3)) { _ in memorySection }

            Divider()
            modelsSection

            Divider()
            workSection

            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }

    private var memorySection: some View {
        let total = LocalMLXEngine.physicalRAMGB
        let free = LocalMLXEngine.freeRAMGB
        let used = max(0, total - free)
        let modelGB = loadedModels.compactMap(\.ramGB).reduce(0, +)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Unified memory", systemImage: "memorychip")
                Spacer()
                Text(String(format: "%.0f GB free of %.0f GB", free, total))
                    .font(.system(size: 11, design: .monospaced))
            }
            .font(.system(size: 11.5, weight: .medium))
            ProgressView(value: min(1, used / max(total, 1)))
                .tint(used / max(total, 1) > 0.85 ? .red : (used / max(total, 1) > 0.7 ? .orange : .green))
            if modelGB > 0 {
                Text(String(format: "Loaded models hold about %.0f GB", modelGB))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models in memory").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            if loadedModels.isEmpty {
                Text("None loaded").font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            ForEach(loadedModels, id: \.id) { model in
                HStack {
                    Text(model.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let ram = model.ramGB {
                        Text(String(format: "~%.0f GB", ram)).font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary)
                    }
                    Button { appState.unloadMLXModel(id: model.id) } label: { Image(systemName: "eject.fill") }
                        .buttonStyle(.borderless)
                        .help("Unload \(model.name)")
                }
            }
        }
    }

    private var workSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background work").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            if appState.backgroundRuns.isEmpty && runningLoops.isEmpty {
                Text("Nothing running").font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            ForEach(appState.backgroundRuns) { run in
                Label(run.title, systemImage: "bolt.fill").font(.system(size: 11.5)).lineLimit(1)
            }
            ForEach(runningLoops, id: \.id) { loop in
                Label("\(loop.title) — pass \(loop.pass) of \(loop.maxPasses)", systemImage: "repeat")
                    .font(.system(size: 11.5)).lineLimit(1)
            }
            Text("\(enabledAutomations) automation\(enabledAutomations == 1 ? "" : "s") enabled · \(scheduledLoops) scheduled loop\(scheduledLoops == 1 ? "" : "s")")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("New Session") {
                showApp()
                appState.createNewSession()
            }
            if appState.isGenerating {
                Button("Stop Current Generation") { appState.cancelCurrentGeneration() }
            }
            if !appState.loadedMLXModelIds.isEmpty {
                Button("Unload All Models") { appState.unloadAllMLXModels() }
            }
            Button("Show SwiftOpenWork") { showApp() }
            Divider()
            Button("Quit SwiftOpenWork") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.hitTestable)
        .font(.system(size: 12))
    }

    private func showApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if NSApplication.shared.windows.allSatisfy({ !$0.isVisible || !$0.canBecomeMain }) {
            // The main window was closed; MenuBarExtra keeps the app alive, so reopen it.
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}
