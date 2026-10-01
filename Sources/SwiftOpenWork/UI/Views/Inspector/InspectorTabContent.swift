import SwiftUI
import SwiftOpenWorkEngine

/// One inspector pane's content. Shared by the inspector and by detached windows, so a pane is the
/// same view wherever it is shown.
struct InspectorTabContent: View {
    @ObservedObject var appState: AppState
    let tab: InspectorTab

    var body: some View {
        switch tab {
        case .editor:
            EditorPane(appState: appState)
        case .preview:
            PreviewPane(appState: appState)
        case .subagents:
            SubAgentTreeVisualizer(appState: appState)
        case .comms:
            // The selection is corrected in `AppState.settings.didSet`, not here. Mutating
            // an `@Published` from a view body's `onAppear` — which is what this used to do
            // — publishes a change during a view update, and `inspectorTab.didSet` writes to
            // `WindowLayoutStore` on top of that.
            if appState.settings.showInterAgentCommunicationLogs {
                InterAgentCommLogView(appState: appState)
            } else {
                SubAgentTreeVisualizer(appState: appState)
            }
        case .artifacts:
            ArtifactsPanelView(appState: appState)
        case .files:
            FilesPanelView(appState: appState)
        case .tools:
            ToolsPanelView(appState: appState)
        case .terminal:
            TerminalPane(appState: appState)
        }
    }
}

/// The Terminal tab: a real shell, or the log of what the agent ran.
struct TerminalPane: View {
    @ObservedObject var appState: AppState
    @AppStorage("terminal.interactive") private var interactive = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $interactive) {
                Text("Interactive").tag(true)
                Text("Command Log").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .help("Interactive is a real shell; Command Log shows what the agent ran")
            Divider()
            if interactive {
                InteractiveTerminalView(appState: appState)
            } else {
                IntegratedTerminalView(appState: appState)
            }
        }
    }
}

/// Stands in for a pane that is open in its own window.
struct DetachedPanePlaceholder: View {
    @ObservedObject var appState: AppState
    let tab: InspectorTab
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text("\(tab.title) is open in its own window")
                .font(.system(size: 12, weight: .semibold))
            HStack {
                Button("Show Window") { openWindow(id: "pane", value: tab) }
                Button("Bring Back Here") { dismissWindow(id: "pane", value: tab) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// The contents of a detached pane's window.
struct DetachedPaneWindow: View {
    @ObservedObject var appState: AppState
    let tab: InspectorTab

    var body: some View {
        InspectorTabContent(appState: appState, tab: tab)
            .frame(minWidth: 420, minHeight: 320)
            .background(ThemeColors.paneBg(for: appState.settings.theme, translucent: false))
            .navigationTitle("\(tab.title) — \(appState.currentWorkspace.name)")
            // The pane has one live instance, so while this window exists the inspector shows a
            // placeholder rather than a second copy.
            .onAppear { appState.detachedPanes.insert(tab) }
            .onDisappear { appState.detachedPanes.remove(tab) }
    }
}
