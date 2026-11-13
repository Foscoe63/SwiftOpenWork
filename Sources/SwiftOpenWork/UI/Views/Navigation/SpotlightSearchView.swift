import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

// MARK: - Model

/// One row in the command palette.
public struct PaletteItem: Identifiable {
    public enum Kind: String, CaseIterable {
        case command = "Command"
        case file = "File"
        case symbol = "Symbol"
        case session = "Chat"
        case agent = "Agent"
        case setting = "Settings"

        var icon: String {
            switch self {
            case .command: return "command"
            case .file: return "doc.text"
            case .symbol: return "curlybraces"
            case .session: return "bubble.left.and.bubble.right"
            case .agent: return "person.crop.circle"
            case .setting: return "gearshape"
            }
        }
    }

    /// Stable, so recently used commands can be remembered across launches.
    public let id: String
    public var title: String
    public var subtitle: String
    public var icon: String
    public var kind: Kind
    public var shortcut: String?
    public var keywords: [String]
    // `@Sendable` is implied by `@MainActor` in the Swift 6 mode but not in Swift 5, and the two
    // spell the type differently in the symbol name. Written out, so the Swift 5 test bundles link.
    public var action: @MainActor @Sendable () -> Void

    public init(id: String, title: String, subtitle: String = "", icon: String? = nil, kind: Kind,
                shortcut: String? = nil, keywords: [String] = [], action: @escaping @MainActor @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon ?? kind.icon
        self.kind = kind
        self.shortcut = shortcut
        self.keywords = keywords
        self.action = action
    }
}

/// Ranks palette items against what was typed. Pure, for tests.
public enum PaletteRanker {

    /// How well `query` matches `text`, or nil for no match. Higher is better.
    ///
    /// Prefix beats the start of a word, which beats a substring, which beats the letters appearing
    /// in order — so "nps" finds "New Preview Tab" but "new" puts "New Session" above it.
    public static func score(query: String, text: String) -> Int? {
        let q = query.lowercased()
        let t = text.lowercased()
        guard !q.isEmpty else { return 0 }
        if t == q { return 1_000 }
        if t.hasPrefix(q) { return 900 - t.count }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 750 - t.count }
        // Initials: "fip" → "Find in Project".
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(q) { return 700 - t.count }
        if t.contains(q) { return 600 - t.count }
        var index = t.startIndex
        var gaps = 0
        var previous: String.Index?
        for character in q {
            guard let found = t[index...].firstIndex(of: character) else { return nil }
            if let previous, t.index(after: previous) != found { gaps += 1 }
            previous = found
            index = t.index(after: found)
        }
        return 300 - gaps * 12 - t.count / 3
    }

    public static func rank(_ items: [PaletteItem], query: String, recent: [String] = [], limit: Int = 60) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            let recentItems = recent.compactMap { id in items.first { $0.id == id } }
            let rest = items.filter { item in item.kind == .command && !recent.contains(item.id) }
            return Array((recentItems + rest).prefix(limit))
        }
        var scored: [(PaletteItem, Int)] = []
        for item in items {
            let best = ([item.title] + item.keywords).compactMap { score(query: trimmed, text: $0) }.max()
            guard var value = best else { continue }
            if let position = recent.firstIndex(of: item.id) { value += 60 - position * 5 }
            // Commands are what the palette is for; at equal quality they come first.
            if item.kind == .command { value += 15 }
            scored.append((item, value))
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// What a leading character narrows the palette to: `>` commands, `@` symbols, `:` a line.
    public enum Mode: Equatable {
        case everything(String)
        case commands(String)
        case symbols(String)
        case line(Int?)
    }

    public static func mode(for query: String) -> Mode {
        if query.hasPrefix(">") { return .commands(String(query.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        if query.hasPrefix("@") { return .symbols(String(query.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        if query.hasPrefix(":") { return .line(Int(query.dropFirst().trimmingCharacters(in: .whitespaces))) }
        return .everything(query)
    }
}

/// Recently run palette items, most recent first.
enum PaletteRecents {
    private static let key = "commandPalette.recent"
    static let limit = 8

    static var ids: [String] {
        (AppIdentity.defaults.array(forKey: key) as? [String]) ?? []
    }

    static func record(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        AppIdentity.defaults.set(Array(list.prefix(limit)), forKey: key)
    }
}

// MARK: - Commands

@MainActor
enum PaletteCommands {

    static func all(appState: AppState, close: @escaping () -> Void) -> [PaletteItem] {
        func command(_ id: String, _ title: String, _ subtitle: String = "", icon: String, shortcut: String? = nil,
                     keywords: [String] = [], _ action: @escaping @MainActor @Sendable () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd." + id, title: title, subtitle: subtitle, icon: icon, kind: .command,
                        shortcut: shortcut, keywords: keywords) {
                close()
                action()
            }
        }
        func toChat() {
            if appState.navigationDestination != .chat && appState.navigationDestination != .tools {
                appState.navigationDestination = .chat
            }
        }
        let sessions = PreviewSessions.shared
        let editors = EditorWorkspace.shared

        var items: [PaletteItem] = [
            command("newSession", "New Chat", "Start a fresh session", icon: "square.and.pencil", shortcut: "⌘N", keywords: ["session", "conversation"]) {
                appState.createNewSession()
                appState.navigationDestination = .chat
            },
            command("findInProject", "Find in Project", "Search every file in the workspace", icon: "text.magnifyingglass", shortcut: "⇧⌘F", keywords: ["search", "grep", "replace"]) {
                appState.showProjectSearch()
            },
            command("showEditor", "Show Editor", icon: "chevron.left.forwardslash.chevron.right", shortcut: "⇧⌘E", keywords: ["code"]) {
                toChat()
                appState.revealInspector(tab: .editor, minimumWidth: 560)
            },
            command("saveAll", "Save All", "Write every unsaved editor tab", icon: "square.and.arrow.down.on.square", shortcut: "⌥⌘S") {
                if let failure = editors.saveAll().first {
                    appState.showToast("\(failure.fileName): \(failure.reason)")
                } else {
                    appState.showToast("Saved")
                }
            },
            command("closeSavedTabs", "Close Saved Editor Tabs", icon: "xmark.square") {
                for document in editors.documents where !document.isDirty { editors.close(document.id) }
            },
            command("toggleSuggestions", appState.settings.inlineSuggestionsEnabled ? "Turn Off Inline AI Suggestions" : "Turn On Inline AI Suggestions",
                    icon: "sparkles", keywords: ["ghost", "completion", "copilot"]) {
                appState.settings.inlineSuggestionsEnabled.toggle()
            },
            command("showPreview", "Show Preview", icon: "safari", shortcut: "⇧⌘P", keywords: ["browser", "web", "localhost"]) {
                toChat()
                appState.revealInspector(tab: .preview, minimumWidth: 560)
            },
            command("newPreviewTab", "New Preview Tab", icon: "plus.rectangle.on.rectangle", shortcut: "⌥⌘T") {
                sessions.newTab(workspaceRoot: appState.currentWorkspace.folderPath)
                toChat()
                appState.revealInspector(tab: .preview, minimumWidth: 560)
            },
            command("reloadPreview", "Reload Preview", icon: "arrow.clockwise") {
                sessions.active.reload()
            },
            command("previewSideBySide", "Previews Side by Side", icon: "rectangle.split.2x1") {
                sessions.layout = .sideBySide
                toChat()
                appState.revealInspector(tab: .preview, minimumWidth: 900)
            },
            command("previewStacked", "Previews Stacked", icon: "rectangle.split.1x2") {
                sessions.layout = .stacked
                toChat()
                appState.revealInspector(tab: .preview, minimumWidth: 560)
            },
            command("previewSingle", "One Preview at a Time", icon: "rectangle") {
                sessions.layout = .single
            },
            command("stopServers", "Stop All Dev Servers", icon: "stop.circle", keywords: ["kill", "npm"]) {
                let count = DevServerManager.shared.liveServers.count
                DevServerManager.shared.stopAll()
                appState.showToast(count == 0 ? "No dev servers were running" : "Stopped \(count) server\(count == 1 ? "" : "s")")
            },
            command("togglePlan", appState.settings.planModeEnabled ? "Turn Off Plan Mode" : "Turn On Plan Mode",
                    "Plan mode blocks writes until the plan is approved", icon: "list.bullet.clipboard") {
                appState.settings.planModeEnabled.toggle()
            },
            command("stopGenerating", "Stop Generating", icon: "stop.fill", keywords: ["cancel"]) {
                appState.cancelCurrentGeneration()
            },
            command("toggleInspector", appState.isInspectorOpen ? "Hide Inspector" : "Show Inspector", icon: "sidebar.right") {
                toChat()
                appState.isInspectorOpen.toggle()
            },
            command("toggleTheme", appState.settings.theme == .light ? "Switch to Dark Theme" : "Switch to Light Theme", icon: "circle.lefthalf.filled", keywords: ["appearance"]) {
                appState.settings.theme = appState.settings.theme == .light ? .dark : .light
            },
        ]

        for tab in InspectorTab.allCases where tab != .editor && tab != .preview {
            items.append(command("inspector.\(tab.rawValue)", "Show \(tab.title)", "Inspector", icon: tab.icon) {
                toChat()
                appState.revealInspector(tab: tab, minimumWidth: 320)
            })
        }
        for destination in NavigationDestination.allCases {
            items.append(command("go.\(destination.rawValue)", "Go to \(destination.displayName)", icon: "arrow.right.circle") {
                appState.navigationDestination = destination
            })
        }
        return items
    }

    static let settingsTabs: [(id: String, title: String)] = [
        ("general", "General"), ("preferences", "Preferences"), ("ai", "AI Model Providers"),
        ("mlx", "Apple Silicon MLX Engine"), ("permissions", "Permissions & Authorized Folders"),
        ("skills", "Skills & MCP"), ("appearance", "Appearance & Styling"), ("advanced", "Advanced Multi-Agent"),
        ("extensions", "Extensions & Plugins"), ("environment", "Environment Variables"),
        ("watchFolders", "Watch Folders"), ("memory", "Long-Term Memory"), ("updates", "Updates & Diagnostics"),
        ("recovery", "Backup & Recovery"), ("debug", "Debug & Developer Logs"),
    ]
}

// MARK: - View

/// The command palette (⌘K): commands, files, chats, agents, settings and symbols in one list.
///
/// Kept under its old name because MainView presents it; it replaces a search dialog that listed
/// only top-level files, opened the file browser rather than the file, and could not be driven
/// from the keyboard.
public struct SpotlightSearchView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @State private var files: [String] = []
    @FocusState private var focused: Bool

    public init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._isPresented = isPresented
    }

    private var theme: AppTheme { appState.settings.theme }

    private func close() { isPresented = false }

    private var results: [PaletteItem] {
        let root = appState.currentWorkspace.folderPath
        switch PaletteRanker.mode(for: query) {
        case .commands(let text):
            return PaletteRanker.rank(PaletteCommands.all(appState: appState, close: close), query: text, recent: PaletteRecents.ids)
        case .symbols(let text):
            guard !text.isEmpty else { return [] }
            let names = EditorWorkspace.shared.workspaceSymbols
            let items = names.map { name in
                PaletteItem(id: "symbol.\(name)", title: name, subtitle: "Jump to its declaration", kind: .symbol) {
                    close()
                    Task { @MainActor in
                        if let found = await EditorWorkspace.shared.definition(of: name, workspaceRoot: root) {
                            appState.openInEditor(path: found.path, line: found.line)
                        } else {
                            appState.showToast("No declaration of \(name) found")
                        }
                    }
                }
            }
            return PaletteRanker.rank(items, query: text, limit: 40)
        case .line(let number):
            guard let document = EditorWorkspace.shared.activeDocument else {
                return [PaletteItem(id: "line.none", title: "Open a file in the editor first", kind: .command) {}]
            }
            let count = document.text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            guard let number, number > 0 else {
                return [PaletteItem(id: "line.hint", title: "Type a line number (1–\(count)) in \(document.fileName)", kind: .command) {}]
            }
            return [PaletteItem(id: "line.go", title: "Go to line \(min(number, count)) in \(document.fileName)", icon: "arrow.down.to.line", kind: .command) {
                close()
                appState.openInEditor(path: document.path, line: min(number, count))
            }]
        case .everything(let text):
            var items = PaletteCommands.all(appState: appState, close: close)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                for relative in QuickOpenMatcher.rank(files: files, query: trimmed).prefix(30) {
                    items.append(PaletteItem(id: "file.\(relative)", title: (relative as NSString).lastPathComponent,
                                             subtitle: relative, kind: .file, keywords: [relative]) {
                        close()
                        appState.openInEditor(path: (root as NSString).appendingPathComponent(relative))
                    })
                }
                for session in appState.sessions.prefix(200) {
                    items.append(PaletteItem(id: "session.\(session.id)", title: session.title,
                                             subtitle: "\(session.messages.count) messages", kind: .session) {
                        close()
                        appState.selectSession(session)
                        appState.navigationDestination = .chat
                    })
                }
                for agent in appState.agents {
                    items.append(PaletteItem(id: "agent.\(agent.id)", title: agent.name, subtitle: "Switch to this agent · \(agent.role)",
                                             kind: .agent, keywords: [agent.role]) {
                        close()
                        appState.setActiveAgent(agent.id)
                        appState.navigationDestination = .chat
                    })
                }
                for tab in PaletteCommands.settingsTabs {
                    items.append(PaletteItem(id: "settings.\(tab.id)", title: "\(tab.title) Settings", subtitle: "Settings", kind: .setting) {
                        close()
                        appState.navigationDestination = .settings
                        appState.settingsTab = tab.id
                    })
                }
            } else {
                // Recently opened files are as likely a destination as a command.
                for document in EditorWorkspace.shared.documents.prefix(5) {
                    items.append(PaletteItem(id: "file.\(document.path)", title: document.fileName,
                                             subtitle: EditorWorkspace.relativePath(document.path, root: root), kind: .file) {
                        close()
                        appState.openInEditor(path: document.path)
                    })
                }
            }
            return PaletteRanker.rank(items, query: trimmed, recent: PaletteRecents.ids)
        }
    }

    public var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 15))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                TextField("Run a command or open a file…   > commands   @ symbols   : line", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { run(items, at: selection) }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Text("esc")
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(ThemeColors.border(for: theme))
                    .cornerRadius(4)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(ThemeColors.sidebarBg(for: theme))

            Divider()

            if items.isEmpty {
                Text(query.hasPrefix("@") && query.count > 1 ? "No declared names match." : "Nothing matches.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                // A button, not a tap gesture: clickable across the row, and reachable
                                // by VoiceOver and accessibility automation.
                                Button {
                                    run(items, at: index)
                                } label: {
                                    row(item, isSelected: index == selection)
                                }
                                .buttonStyle(.hitTestable)
                                .id(item.id)
                                .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selection) { _, value in
                        guard items.indices.contains(value) else { return }
                        proxy.scrollTo(items[value].id)
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Text("↑↓ choose   ⏎ run")
                Spacer()
                Text("> commands   @ symbols   : go to line")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 640, height: 460)
        .background(ThemeColors.bg(for: theme))
        .cornerRadius(12)
        .shadow(radius: 20)
        .onAppear {
            focused = true
            let root = appState.currentWorkspace.folderPath
            Task.detached(priority: .userInitiated) {
                let listed = WorkspaceFileScanner.listFiles(at: root)
                await MainActor.run { files = listed }
            }
            if EditorWorkspace.shared.workspaceSymbols.isEmpty {
                EditorWorkspace.shared.refreshSymbols(root: root)
            }
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Text(item.kind.rawValue)
                .font(.system(size: 9.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ThemeColors.border(for: theme).opacity(0.6))
                .cornerRadius(4)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.18) : Color.clear)
        .cornerRadius(7)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func run(_ items: [PaletteItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if item.kind == .command || item.kind == .file {
            PaletteRecents.record(item.id)
        }
        item.action()
    }
}
