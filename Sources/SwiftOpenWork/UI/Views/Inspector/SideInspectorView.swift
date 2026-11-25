import SwiftUI
import SwiftOpenWorkEngine

public struct SideInspectorView: View {
    @ObservedObject var appState: AppState
    /// Watched so the Mods tab appears when a mod opens a pane.
    @ObservedObject private var mods = ModHost.shared
    @Environment(\.openWindow) private var openWindow

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        // A GeometryReader has no minimum size of its own, so nothing inside can make the inspector
        // wider than the column it was given. Without it, a pane with a wide minimum (a mod's pane
        // with a fixed-width row, say) overflowed the column on both sides: the tab bar was cut off
        // at the edges and the overflow sat on top of the drag handle, so the sidebar could not be
        // resized.
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Inspector Tab Bar
                inspectorTabBar

                Divider()
                    .background(ThemeColors.border(for: appState.settings.theme))

                // Tab Content
                if appState.detachedPanes.contains(appState.inspectorTab) {
                    DetachedPanePlaceholder(appState: appState, tab: appState.inspectorTab)
                } else {
                    // A pane that is wider than the inspector (a mod's content) must not
                    // widen the stack and push the tab bar off its edge.
                    InspectorTabContent(appState: appState, tab: appState.inspectorTab)
                        .frame(width: geo.size.width, alignment: .topLeading)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColors.paneBg(for: appState.settings.theme, translucent: appState.settings.useTranslucentBackground))
    }

    /// `showInterAgentCommunicationLogs` had no reader and no control — the Agent Messages tab
    /// was always here. Hiding the selected tab has to move the selection, or the inspector shows
    /// a tab bar with nothing selected and the content of a tab the user just switched off.
    private var visibleTabs: [InspectorTab] {
        InspectorTab.allCases.filter {
            ($0 != .comms || appState.settings.showInterAgentCommunicationLogs)
                && ($0 != .mods || !ModHost.shared.panes.isEmpty || appState.inspectorTab == .mods)
        }
    }

    // MARK: - Inspector Tab Bar

    /// Two rows rather than one. Nine tabs in a single row did not fit a narrow inspector, so the
    /// bar was cut off at the edges. The pop-out button ends the second row.
    private var inspectorTabBar: some View {
        let tabs = visibleTabs
        let split = (tabs.count + 1) / 2
        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                ForEach(Array(tabs.prefix(split))) { tabButton($0) }
            }
            HStack(spacing: 4) {
                ForEach(Array(tabs.dropFirst(split))) { tabButton($0) }

                Button {
                    openWindow(id: "pane", value: appState.inspectorTab)
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .frame(width: 24, height: 36)
                }
                .buttonStyle(.hitTestable)
                .help("Open \(appState.inspectorTab.title) in its own window")
            }
        }
        .padding(6)
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let isSelected = appState.inspectorTab == tab
        return Button {
            if tab == .editor || tab == .preview {
                // Code and web pages are unreadable at the inspector's narrow default.
                appState.revealInspector(tab: tab, minimumWidth: 480)
            } else {
                appState.inspectorTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    // A fixed box, because these glyphs are not the same shape:
                    // `bubble.left.and.exclamationmark.bubble.right.fill` measures 23pt
                    // wide against 15-19 for the others, so that tab rendered edge to
                    // edge with no clear margin.
                    .frame(width: 20, height: 16)
                Text(tab.title)
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // minWidth 0 lets the row shrink at the narrowest inspector width
                    // instead of the label's natural width pushing the bar past the edge.
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
            .frame(minWidth: 0, maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.hitTestable)
        .help(tab.title)
    }
}

public struct IntegratedTerminalView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var terminalSession = WorkspaceTerminalSession.shared
    @State private var inputCommand: String = ""
    @FocusState private var isInputFocused: Bool
    @State private var historyIndex: Int = -1

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(terminalSession.isRunning ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(terminalSession.isRunning ? "RUNNING" : "READY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(terminalSession.isRunning ? .orange : .green)
                }

                // Shell badge / selector
                Menu {
                    Button("Zsh (/bin/zsh)") {
                        appState.settings.terminalShell = "/bin/zsh"
                        appState.updateSettings(appState.settings)
                        WorkspaceTerminalSession.shared.activeShellName = "zsh"
                    }
                    Button("Bash (/bin/bash)") {
                        appState.settings.terminalShell = "/bin/bash"
                        appState.updateSettings(appState.settings)
                        WorkspaceTerminalSession.shared.activeShellName = "bash"
                    }
                    Button("POSIX sh (/bin/sh)") {
                        appState.settings.terminalShell = "/bin/sh"
                        appState.updateSettings(appState.settings)
                        WorkspaceTerminalSession.shared.activeShellName = "sh"
                    }
                    Button("Fish (/opt/homebrew/bin/fish)") {
                        appState.settings.terminalShell = "/opt/homebrew/bin/fish"
                        appState.updateSettings(appState.settings)
                        WorkspaceTerminalSession.shared.activeShellName = "fish"
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "terminal")
                            .font(.system(size: 9))
                        Text(terminalSession.activeShellName)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(ThemeColors.border(for: appState.settings.theme))
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                // Quick command presets
                HStack(spacing: 4) {
                    Button("ls") {
                        terminalSession.execute(command: "ls -la", in: appState.currentWorkspace.folderPath)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button("git") {
                        terminalSession.execute(command: "git status", in: appState.currentWorkspace.folderPath)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button("pwd") {
                        terminalSession.execute(command: "pwd", in: appState.currentWorkspace.folderPath)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Button("Clear") {
                    terminalSession.clear()
                }
                .font(.system(size: 10))
                .buttonStyle(.hitTestable)
                .foregroundColor(.secondary)

                if terminalSession.isRunning {
                    Button("Stop", role: .destructive) {
                        terminalSession.terminate()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .buttonStyle(.hitTestable)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ThemeColors.paneBg(for: appState.settings.theme, translucent: appState.settings.useTranslucentBackground))

            Divider()

            // Console Output ScrollView (Clicking anywhere focuses the terminal input)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(terminalSession.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(line.isError ? Color.red.opacity(0.9) : (line.text.hasPrefix("$") || line.text.contains(" $ ") ? Color.green : Color.white.opacity(0.85)))
                                .textSelection(.enabled)
                                .id(line.id)
                        }

                        // Live interactive active prompt line in the terminal body
                        HStack(spacing: 6) {
                            Text("[\((appState.currentWorkspace.folderPath as NSString).lastPathComponent)] $")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)

                            if !inputCommand.isEmpty {
                                Text(inputCommand)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white)
                            }

                            // Blinking Terminal Cursor indicator
                            Rectangle()
                                .fill(terminalSession.isRunning ? Color.orange : Color.green)
                                .frame(width: 7, height: 13)
                                .opacity(terminalSession.isRunning ? 0.4 : 0.9)
                        }
                        .padding(.top, 4)
                        .id("active-terminal-prompt")
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.88))
                .contentShape(Rectangle())
                .onTapGesture {
                    isInputFocused = true
                }
                .onMessageCountChanged(count: terminalSession.lines.count) {
                    withAnimation {
                        proxy.scrollTo("active-terminal-prompt", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Working directory indicator
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                Text(appState.currentWorkspace.name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
                Text("•")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Text(appState.currentWorkspace.folderPath)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.4))

            Divider()

            // Prominent Command Prompt Input Bar
            HStack(spacing: 6) {
                Text("[\((appState.currentWorkspace.folderPath as NSString).lastPathComponent)] $")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)

                TextField("Type shell command (e.g. ls, git, cargo, swift, python3)...", text: $inputCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($isInputFocused)
                    .onSubmit {
                        executeCurrentCommand()
                    }

                if !inputCommand.isEmpty {
                    Button {
                        inputCommand = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.hitTestable)
                }

                Button {
                    executeCurrentCommand()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(inputCommand.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : ThemeColors.accent(for: appState.settings.accentColor))
                }
                .buttonStyle(.hitTestable)
                .disabled(inputCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ThemeColors.cardBg(for: appState.settings.theme))
        }
        .onAppear {
            isInputFocused = true
        }
    }

    private func executeCurrentCommand() {
        guard !inputCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cmd = inputCommand
        inputCommand = ""
        terminalSession.execute(command: cmd, in: appState.currentWorkspace.folderPath)
        isInputFocused = true
    }
}
