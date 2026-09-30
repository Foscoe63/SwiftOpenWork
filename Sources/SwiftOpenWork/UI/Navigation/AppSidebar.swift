import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

public struct AppSidebar: View {
    @ObservedObject var appState: AppState
    @State private var showAllWorkspaceSessions: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Workspace Header
            workspaceHeader

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Navigation Items List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    navButton(for: .chat, count: appState.sessions.filter { !$0.isArchived }.count)
                    navButton(for: .localModels, count: appState.localMLXModels.filter { $0.isDownloaded }.count)
                    navButton(for: .agents, count: appState.agents.count)
                    navButton(for: .providers, count: appState.providers.filter { $0.isEnabled }.count)
                    navButton(for: .automations, count: appState.automations.filter { $0.isEnabled }.count)
                    navButton(for: .loops, count: appState.loops.filter { $0.state == .running }.count)
                    navButton(for: .watchFolders, count: appState.watchItems.filter { $0.isEnabled }.count)
                    // No badge: this row opens a browser over the workspace folder, but
                    // `appState.artifacts` holds `AutomationArtifact` records, which are shown
                    // under Watch Folders. The badge read 0 on a workspace full of files, and
                    // read 3 for three records this page will never display.
                    navButton(for: .artifacts, count: nil)
                    navButton(for: .memory, count: appState.memories.count)
                    navButton(for: .tools, count: appState.tools.filter { $0.isEnabled }.count)
                    navButton(for: .dashboard, count: nil)

                    // Sessions subsection when in Chat mode
                    if appState.navigationDestination == .chat {
                        sessionsListSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Bottom Footer (Settings & Status)
            bottomFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColors.paneBg(for: appState.settings.theme, translucent: appState.settings.useTranslucentBackground))
    }

    // MARK: - Workspace Header
    private var workspaceHeader: some View {
        WorkspaceSwitcherMenu(appState: appState, onSelectWorkspace: { id in
            appState.switchWorkspace(to: id)
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: appState.currentWorkspace.color))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.currentWorkspace.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .lineLimit(1)

                    // `compactSidebar` was a stored Bool with neither a reader nor a control.
                    // Compact means fewer secondary lines and tighter rows, not a narrower
                    // pane — the width is a drag handle the user already owns.
                    if !appState.settings.compactSidebar {
                        Text(workspaceSubtitle(for: appState.currentWorkspace))
                            .font(.system(size: 9.5))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, appState.settings.compactSidebar ? 5 : 8)
            .contentShape(Rectangle())
        }
    }

    private func workspaceSubtitle(for workspace: Workspace) -> String {
        if let agentId = workspace.assignedAgentId, let agent = appState.agents.first(where: { $0.id == agentId }) {
            return "\(agent.role) Sandbox"
        }
        return workspace.category.displayName
    }

    // MARK: - Navigation Button
    private func navButton(for destination: NavigationDestination, count: Int?) -> some View {
        let isSelected = appState.navigationDestination == destination
        return Button {
            appState.navigationDestination = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))

                Text(destination.displayName)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))

                Spacer()

                if let count = count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.15) : ThemeColors.border(for: appState.settings.theme).opacity(0.6))
                        .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, appState.settings.compactSidebar ? 3 : 6.5)
            .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
            .cornerRadius(8)
        }
        // An unselected row draws `Color.clear` behind a `Spacer()`, so under `.plain` the only
        // clickable pixels were the letters and the icon's strokes. Clicking the icon usually
        // landed between the strokes and did nothing.
        .buttonStyle(.hitTestable)
    }

    // MARK: - Sessions List in Sidebar
    private var sessionsListSection: some View {
        let activeSessions = appState.sessions.filter {
            !$0.isArchived && (showAllWorkspaceSessions || $0.workspaceId == appState.activeWorkspaceId)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(showAllWorkspaceSessions ? "ALL SESSIONS" : "WORKSPACE SESSIONS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.7))
                    .padding(.leading, 8)
                    .padding(.top, 10)

                Spacer()

                Button {
                    showAllWorkspaceSessions.toggle()
                } label: {
                    Image(systemName: showAllWorkspaceSessions ? "tray.full.fill" : "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.hitTestable)
                .help(showAllWorkspaceSessions ? "Show Active Workspace Only" : "Show All Workspaces")

                if appState.agents.count >= 2 {
                    Button {
                        appState.isGroupPickerPresented = true
                    } label: {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.hitTestable)
                    .help("New Group Chat — several agents in one conversation")
                }

                Button {
                    appState.createNewSession()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                }
                .buttonStyle(.hitTestable)
                .help("New Session (Cmd+N)")
            }

            if activeSessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No chats in \(appState.currentWorkspace.name)")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))

                    Button("Start New Chat") {
                        appState.createNewSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            } else {
                ForEach(activeSessions) { session in
                    let isCurrent = appState.currentSessionId == session.id
                    HStack(spacing: 8) {
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        } else if session.isGroup {
                            // Several agents in the room; the pin above still wins for pinned.
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9))
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        } else if session.forkedFromSessionId != nil {
                            // A fork shares its opening messages with another session; the icon is
                            // what stops the two looking like unrelated conversations in the list.
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        } else {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 10))
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        }

                        Text(session.title)
                            .font(.system(size: 12))
                            .foregroundColor(isCurrent ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isCurrent ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12) : Color.clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectSession(session)
                    }
                    .contextMenu {
                        Button(session.isPinned ? "Unpin Session" : "Pin Session") {
                            appState.togglePinSession(session)
                        }
                        Button("Archive Session") {
                            appState.archiveSession(session)
                        }
                        Divider()
                        Button("Delete Session", role: .destructive) {
                            appState.deleteSession(session)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom Footer
    private var bottomFooter: some View {
        HStack(spacing: 10) {
            Button {
                appState.navigationDestination = .settings
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundColor(appState.navigationDestination == .settings ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))

                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(appState.navigationDestination == .settings ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(appState.navigationDestination == .settings ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.hitTestable)

            Spacer()

            // Standalone node online status
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Online")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
