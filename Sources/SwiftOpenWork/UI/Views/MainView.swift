import SwiftUI
import AppKit

public struct MainView: View {
    @ObservedObject var appState: AppState
    @State private var sidebarWidth: CGFloat = CGFloat(WindowLayoutStore.sidebarWidth)
    @State private var inspectorWidth: CGFloat = CGFloat(WindowLayoutStore.inspectorWidth)
    @State private var sidebarDragOrigin: CGFloat?
    @State private var inspectorDragOrigin: CGFloat?

    public init(appState: AppState) {
        self.appState = appState
    }

    private var showInspector: Bool {
        appState.isInspectorOpen
            && (appState.navigationDestination == .chat || appState.navigationDestination == .tools)
    }

    public var body: some View {
        ZStack {
            if appState.navigationDestination == .settings {
                SettingsView(appState: appState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Custom split: fixed sidebar widths + flexible center.
                // Do NOT add a second flexible .frame(min/max) on the side panes —
                // HStack will expand those and leave empty gutters around the content.
                HStack(spacing: 0) {
                    AppSidebar(appState: appState)
                        .frame(width: sidebarWidth)
                        .clipped()

                    splitHandle(
                        origin: $sidebarDragOrigin,
                        current: sidebarWidth,
                        minWidth: WindowLayoutStore.minSidebarWidth,
                        maxWidth: WindowLayoutStore.maxSidebarWidth
                    ) { newWidth in
                        sidebarWidth = newWidth
                        WindowLayoutStore.sidebarWidth = Double(newWidth)
                    }

                    centerContent
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)

                    if showInspector {
                        splitHandle(
                            origin: $inspectorDragOrigin,
                            current: inspectorWidth,
                            minWidth: WindowLayoutStore.minInspectorWidth,
                            maxWidth: WindowLayoutStore.maxInspectorWidth,
                            inverted: true
                        ) { newWidth in
                            inspectorWidth = newWidth
                            WindowLayoutStore.inspectorWidth = Double(newWidth)
                        }

                        SideInspectorView(appState: appState)
                            .frame(width: inspectorWidth)
                            .clipped()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let toast = appState.toastMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(20)
                    .shadow(radius: 8)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if appState.isSearchDialogOpen {
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            appState.isSearchDialogOpen = false
                        }

                    SpotlightSearchView(appState: appState, isPresented: $appState.isSearchDialogOpen)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: WindowLayoutStore.minWindowWidth, minHeight: WindowLayoutStore.minWindowHeight)
        // "Translucent Window Background" was a stored switch nothing read. The material goes
        // behind everything; the sidebar and inspector thin their fills so it shows through.
        .background {
            if appState.settings.useTranslucentBackground {
                VisualEffectBackground().ignoresSafeArea()
            }
        }
        .background(WindowFramePersistenceInstaller())
        .onChange(of: appState.inspectorWidthRequest) { _, requested in
            guard let requested else { return }
            appState.inspectorWidthRequest = nil
            let clamped = min(max(requested, WindowLayoutStore.minInspectorWidth), WindowLayoutStore.maxInspectorWidth)
            guard Double(inspectorWidth) < clamped else { return }
            inspectorWidth = CGFloat(clamped)
            WindowLayoutStore.inspectorWidth = clamped
        }
        .onAppear {
            sidebarWidth = CGFloat(WindowLayoutStore.sidebarWidth)
            inspectorWidth = CGFloat(WindowLayoutStore.inspectorWidth)
            WindowLayoutStore.observeMainWindowAutosave()
            WindowLayoutStore.configureMainWindowAutosave()
        }
    }

    /// Drag handle between panes. `inverted` = dragging right shrinks the right pane (inspector).
    private func splitHandle(
        origin: Binding<CGFloat?>,
        current: CGFloat,
        minWidth: Double,
        maxWidth: Double,
        inverted: Bool = false,
        onChange: @escaping (CGFloat) -> Void
    ) -> some View {
        Color.clear
            .frame(width: 6)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if origin.wrappedValue == nil {
                            origin.wrappedValue = current
                        }
                        let base = origin.wrappedValue ?? current
                        let delta = inverted ? -value.translation.width : value.translation.width
                        let next = min(max(base + delta, minWidth), maxWidth)
                        onChange(next)
                    }
                    .onEnded { _ in
                        origin.wrappedValue = nil
                    }
            )
            .layoutPriority(-1)
    }

    // MARK: - Center Content by Destination
    @ViewBuilder
    private var centerContent: some View {
        switch appState.navigationDestination {
        case .chat:
            ChatView(appState: appState)
        case .localModels:
            LocalModelsView(appState: appState)
        case .agents:
            AgentsView(appState: appState)
        case .providers:
            ProvidersView(appState: appState)
        case .automations:
            AutomationsView(appState: appState)
        case .loops:
            LoopsView(appState: appState)
        case .watchFolders:
            WatchFoldersView(appState: appState)
        case .artifacts:
            ArtifactsView(appState: appState)
        case .memory:
            MemoryView(appState: appState)
        case .tools:
            ToolsView(appState: appState)
        case .dashboard:
            DashboardView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        }
    }
}
