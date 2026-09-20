import SwiftUI
import AppKit
import WebKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

public struct PreviewPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var sessions = PreviewSessions.shared
    @ObservedObject private var servers = DevServerManager.shared
    @State private var drawer: Drawer? = nil

    enum Drawer: String, CaseIterable, Identifiable {
        case console = "Console"
        case server = "Server Log"
        var id: String { rawValue }
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    private var theme: AppTheme { appState.settings.theme }
    private var root: String { appState.currentWorkspace.folderPath }

    public var body: some View {
        let active = sessions.active
        VStack(spacing: 0) {
            tabStrip(active: active)
            Divider()
            if let server = server(of: active) {
                ServerStrip(appState: appState, server: server, onShowLog: { drawer = .server }, onRestart: { restart(server, in: active) })
                Divider()
            }
            panels(active: active)
            if let drawer {
                Divider()
                drawerView(drawer, tab: active)
                    .frame(height: 210)
            }
        }
        .background(ThemeColors.bg(for: theme))
        .onAppear {
            for tab in sessions.tabs where tab.workspaceRoot == nil { tab.workspaceRoot = root }
            if active.workspaceRoot == nil { active.workspaceRoot = root }
        }
    }

    // MARK: Tabs and layout

    private func tabStrip(active: PreviewController) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { index, tab in
                        PreviewTabButton(
                            appState: appState,
                            tab: tab,
                            number: index + 1,
                            isActive: tab.id == active.id,
                            isSecondary: tab.id == sessions.secondary?.id,
                            canClose: sessions.tabs.count > 1 || tab.currentURL != nil,
                            onSelect: { sessions.activate(tab.id) },
                            onClose: { sessions.close(tab.id) }
                        )
                        .contextMenu {
                            Button("Duplicate Tab") { sessions.duplicate(tab.id) }
                            if sessions.layout != .single, tab.id != active.id {
                                Button("Show Beside Active Tab") { sessions.secondaryId = tab.id }
                            }
                            Divider()
                            Button("Close Tab") { sessions.close(tab.id) }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Button {
                sessions.newTab(workspaceRoot: root)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.hitTestable)
            .help("New preview tab")
            .disabled(sessions.tabs.count >= PreviewSessions.maxTabs)

            Menu {
                Picker("Layout", selection: $sessions.layout) {
                    ForEach(PreviewSessions.Layout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Duplicate Active Tab") { sessions.duplicate(active.id) }
                    .disabled(active.currentURL == nil)
            } label: {
                Image(systemName: layoutIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 6)
            .help("Show one preview, or two side by side or stacked")
        }
        .frame(height: 30)
        .background(ThemeColors.sidebarBg(for: theme))
    }

    private var layoutIcon: String {
        switch sessions.layout {
        case .single: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked: return "rectangle.split.1x2"
        }
    }

    @ViewBuilder
    private func panels(active: PreviewController) -> some View {
        if let secondary = sessions.secondary {
            if sessions.layout == .sideBySide {
                HSplitView {
                    panel(active, isActive: true)
                    panel(secondary, isActive: false)
                }
            } else {
                VSplitView {
                    panel(active, isActive: true)
                    panel(secondary, isActive: false)
                }
            }
        } else {
            panel(active, isActive: true)
        }
    }

    private func panel(_ tab: PreviewController, isActive: Bool) -> some View {
        PreviewPanel(
            appState: appState,
            tab: tab,
            showsFocusRing: sessions.secondary != nil && isActive,
            onFocus: { sessions.activate(tab.id) },
            onShowConsole: { sessions.activate(tab.id); drawer = drawer == .console ? nil : .console },
            onShowServerLog: { drawer = .server }
        )
        .frame(minWidth: 220, minHeight: 160)
        .id(tab.id)
    }

    private func server(of tab: PreviewController) -> DevServer? {
        if let id = tab.serverId, let found = servers.servers.first(where: { $0.id == id }) { return found }
        return tab.currentURL == nil ? servers.activeServer : nil
    }

    // MARK: Drawer

    @ViewBuilder
    private func drawerView(_ selection: Drawer, tab: PreviewController) -> some View {
        DrawerView(
            appState: appState,
            tab: tab,
            server: server(of: tab),
            selection: selection,
            onSelect: { drawer = $0 },
            onClose: { drawer = nil }
        )
    }

    private func restart(_ server: DevServer, in tab: PreviewController) {
        let kind: DevServerPlan.Kind = server.isStaticServer
            ? .staticFiles(root: server.workingDirectory, entry: "index.html")
            : .command(server.command)
        servers.remove(server)
        let settings = appState.settings
        let workspaceRoot = root
        tab.serverId = nil
        Task {
            _ = await PreviewLauncher.start(
                plan: DevServerPlan(kind: kind, reason: "Restart", caveat: nil),
                workspaceRoot: workspaceRoot,
                settings: settings
            )
        }
    }
}

/// One preview on screen: its own toolbar, page and start panel.
private struct PreviewPanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var tab: PreviewController
    @ObservedObject private var servers = DevServerManager.shared
    let showsFocusRing: Bool
    let onFocus: () -> Void
    let onShowConsole: () -> Void
    let onShowServerLog: () -> Void

    @State private var addressText = ""
    @State private var commandText = ""
    @State private var plan: DevServerPlan?
    @State private var planRoot: String?
    @State private var isStarting = false
    @State private var startFailure: String?

    private var theme: AppTheme { appState.settings.theme }
    private var root: String { appState.currentWorkspace.folderPath }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if tab.currentURL == nil {
                startPanel
            } else {
                page
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ThemeColors.accent(for: appState.settings.accentColor).opacity(showsFocusRing ? 0.7 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .onAppear { [appState] in
            // `tab` belongs to `PreviewSessions.shared`, so it outlives this view and the
            // callback stored on it must not pin AppState — hence `weak` on the inner closure.
            // The outer capture is written out because an implicit strong one here would
            // contradict that, which is what the compiler warns about.
            tab.onElementPicked = { [weak appState] element, png in
                let image = png.flatMap { ComposerAttachmentIntake.attachment(fromPNGData: $0, preferredName: "picked-\(element.tag).png") }
                appState?.addToComposer(text: element.promptText, attachments: image.map { [$0] } ?? [])
                appState?.showToast("Element added to the message box — say what to change")
            }
            if tab.workspaceRoot == nil { tab.workspaceRoot = root }
            refreshPlan()
            addressText = tab.currentURL?.absoluteString ?? ""
        }
        .onChange(of: root) { _, _ in
            tab.workspaceRoot = root
            refreshPlan()
        }
        .onChange(of: tab.currentURL) { _, url in
            addressText = url?.absoluteString ?? ""
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.left", help: "Back", enabled: tab.canGoBack) { tab.goBack() }
            iconButton("chevron.right", help: "Forward", enabled: tab.canGoForward) { tab.goForward() }
            iconButton(tab.isLoading ? "xmark" : "arrow.clockwise",
                       help: tab.isLoading ? "Stop loading" : "Reload (bypassing the cache)",
                       enabled: tab.currentURL != nil) {
                if tab.isLoading { tab.webView.stopLoading() } else { tab.reload() }
            }

            iconButton("cursorarrow.rays",
                       help: tab.isPicking ? "Cancel selecting (Esc)" : "Select an element to ask about it",
                       enabled: tab.currentURL != nil && tab.loadError == nil) {
                if tab.isPicking { tab.stopPicking() } else { tab.startPicking() }
            }
            .background(tab.isPicking ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.25) : Color.clear)
            .cornerRadius(4)
            iconButton("camera", help: "Add a screenshot of the page to the message",
                       enabled: tab.currentURL != nil && tab.loadError == nil) {
                screenshotToComposer()
            }

            TextField("localhost:5173, a port, or a URL", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .onSubmit { openTypedAddress() }

            Menu {
                Picker("Viewport", selection: Binding(get: { tab.viewportWidth ?? 0 }, set: { tab.viewportWidth = $0 == 0 ? nil : $0 })) {
                    Text("Fit Pane").tag(CGFloat(0))
                    Text("Phone — 390").tag(CGFloat(390))
                    Text("Tablet — 768").tag(CGFloat(768))
                    Text("Laptop — 1280").tag(CGFloat(1280))
                }
                Toggle("Reload When Files Change", isOn: $tab.reloadOnSave)
                Divider()
                Button("Open in Browser") {
                    if let url = tab.currentURL { NSWorkspace.shared.open(url) }
                }
                .disabled(tab.currentURL == nil)
            } label: {
                Image(systemName: "rectangle.and.hand.point.up.left")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Viewport and preview options")

            Button(action: onShowConsole) {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                    if tab.problemCount > 0 {
                        Text("\(tab.problemCount)")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 4)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .frame(height: 22)
            }
            .buttonStyle(.hitTestable)
            .help("Console: errors, warnings and failed requests from this page")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(ThemeColors.sidebarBg(for: theme))
    }

    private func screenshotToComposer() {
        let url = tab.currentURL?.absoluteString ?? "the preview"
        Task {
            guard let png = await tab.snapshotPNG(),
                  let image = ComposerAttachmentIntake.attachment(fromPNGData: png, preferredName: "preview.png") else {
                appState.showToast("Could not take a screenshot of the page")
                return
            }
            appState.addToComposer(text: "Screenshot of \(url) attached.", attachments: [image])
            appState.showToast("Screenshot added to the message box")
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.hitTestable)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    // MARK: Page

    private var page: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let width = tab.viewportWidth {
                ScrollView(.horizontal) {
                    WebViewHost(controller: tab)
                        .frame(width: width)
                }
            } else {
                WebViewHost(controller: tab)
            }
            if let error = tab.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    HStack {
                        Button("Retry") { tab.reload() }
                        if tab.serverId != nil {
                            Button("Server Log", action: onShowServerLog)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(20)
                .background(.regularMaterial)
                .cornerRadius(10)
            }
        }
    }

    // MARK: Start panel

    private var startPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview what you are building")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Runs the project's dev server and shows it here. The agent sees the same page — its console errors and a screenshot — with preview_check.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !servers.liveServers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Running")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        ForEach(servers.liveServers) { server in
                            if let url = server.url {
                                Button {
                                    tab.workspaceRoot = root
                                    tab.serverId = server.id
                                    tab.reloadOnSave = server.isStaticServer
                                    tab.load(url)
                                } label: {
                                    Label("\(server.command) — \(url.absoluteString)", systemImage: "play.rectangle")
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                    }
                    .padding(12)
                    .background(ThemeColors.cardBg(for: theme))
                    .cornerRadius(8)
                }

                if let plan {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(plan.reason, systemImage: "wand.and.stars")
                            .font(.system(size: 11.5))
                        if plan.command != nil {
                            TextField("Command", text: $commandText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        if let caveat = plan.caveat {
                            Label(caveat, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button {
                                startDetected()
                            } label: {
                                if isStarting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(plan.command == nil ? "Preview Site" : "Start Server", systemImage: "play.fill")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isStarting || (plan.command != nil && commandText.trimmingCharacters(in: .whitespaces).isEmpty))
                            Text("in \(appState.currentWorkspace.name)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(ThemeColors.cardBg(for: theme))
                    .cornerRadius(8)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No dev server or index.html found in \(appState.currentWorkspace.name).")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        TextField("Command to run, e.g. npm run dev", text: $commandText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button {
                            launch(DevServerPlan(kind: .command(commandText.trimmingCharacters(in: .whitespaces)), reason: "Custom command", caveat: nil))
                        } label: {
                            Label("Start Server", systemImage: "play.fill")
                        }
                        .disabled(isStarting || commandText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(12)
                    .background(ThemeColors.cardBg(for: theme))
                    .cornerRadius(8)
                }

                if let startFailure {
                    Label(startFailure, systemImage: "xmark.octagon")
                        .font(.system(size: 11.5))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Already running? Type its address or port in the bar above.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private func refreshPlan() {
        guard planRoot != root else { return }
        planRoot = root
        let detected = DevServerCommandDetector.plan(root: root)
        plan = detected
        commandText = detected?.command ?? ""
    }

    private func startDetected() {
        guard var chosen = plan else { return }
        if chosen.command != nil {
            chosen.kind = .command(commandText.trimmingCharacters(in: .whitespaces))
        }
        launch(chosen)
    }

    private func launch(_ chosen: DevServerPlan) {
        isStarting = true
        startFailure = nil
        let settings = appState.settings
        let workspaceRoot = root
        PreviewSessions.shared.activate(tab.id)
        Task {
            let outcome = await PreviewLauncher.start(plan: chosen, workspaceRoot: workspaceRoot, settings: settings)
            isStarting = false
            if let failure = outcome.failure {
                startFailure = failure
                onShowServerLog()
            }
        }
    }

    private func openTypedAddress() {
        guard let url = PreviewURLPolicy.normalize(typed: addressText) else { return }
        tab.workspaceRoot = root
        tab.load(url)
    }
}

private struct PreviewTabButton: View {
    @ObservedObject var appState: AppState
    @ObservedObject var tab: PreviewController
    let number: Int
    let isActive: Bool
    let isSecondary: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            if tab.isLoading {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else {
                Image(systemName: isSecondary ? "rectangle.righthalf.inset.filled" : "globe")
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)
            }
            Text(tab.displayTitle)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 140)
            if tab.problemCount > 0 {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                    .help("\(tab.problemCount) problem(s) on this page")
            }
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.hitTestable)
                .opacity(hovering || isActive ? 1 : 0)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isActive ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.currentURL?.absoluteString ?? "Empty tab")
    }
}

/// Console and server log for the active tab.
private struct DrawerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var tab: PreviewController
    let server: DevServer?
    let selection: PreviewPane.Drawer
    let onSelect: (PreviewPane.Drawer) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { selection }, set: { onSelect($0) })) {
                    ForEach(PreviewPane.Drawer.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Text(tab.displayTitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if selection == .console {
                    if tab.problemCount > 0 {
                        Button("Ask Agent to Fix") { askAgentToFix() }
                            .controlSize(.small)
                            .help("Put these errors in the message box")
                    }
                    Button("Clear") { tab.clearConsole() }
                        .controlSize(.small)
                } else if let server {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.logTail(2_000), forType: .string)
                    }
                    .controlSize(.small)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.hitTestable)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            switch selection {
            case .console:
                ConsoleList(appState: appState, entries: tab.console)
            case .server:
                if let server {
                    ServerLogView(server: server)
                } else {
                    Text("This tab is not showing a server started here.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func askAgentToFix() {
        let problems = tab.console.filter { $0.level.isProblem }.suffix(12)
        let list = problems.map { "- [\($0.level.rawValue)] \($0.message.prefix(500))" }.joined(separator: "\n")
        let where_ = tab.currentURL?.absoluteString ?? "the preview"
        let number = PreviewSessions.shared.number(of: tab).map { " (preview tab \($0))" } ?? ""
        let text = """
        The page at \(where_)\(number) is showing these errors:
        \(list)

        Find the cause and fix it, then check the page again with preview_check.
        """
        appState.composerText = appState.composerText.isEmpty ? text : appState.composerText + "\n\n" + text
        appState.showToast("Errors added to the message box")
    }
}

// MARK: - Pieces

/// Puts a tab's web view into the panel showing it.
private struct WebViewHost: NSViewRepresentable {
    let controller: PreviewController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.webView.superview !== container {
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let view = controller.webView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        controller.didAttachToPane()
    }
}

private struct ServerStrip: View {
    @ObservedObject var appState: AppState
    @ObservedObject var server: DevServer
    let onShowLog: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if server.status == .starting {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(server.status.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(color)
            Text(server.command)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let url = server.url {
                Text(url.absoluteString)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Log", action: onShowLog)
                .buttonStyle(.hitTestable)
                .font(.system(size: 10.5, weight: .medium))
            if server.status.isLive {
                Button("Stop") { DevServerManager.shared.stop(server) }
                    .buttonStyle(.hitTestable)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.red)
            } else {
                Button("Restart", action: onRestart)
                    .buttonStyle(.hitTestable)
                    .font(.system(size: 10.5, weight: .medium))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme).opacity(0.6))
    }

    private var color: Color {
        switch server.status {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .exited, .failed: return .red
        }
    }
}

private struct ConsoleList: View {
    @ObservedObject var appState: AppState
    let entries: [PreviewConsoleEntry]

    var body: some View {
        if entries.isEmpty {
            Text("Nothing logged. Console output, uncaught errors and failed requests appear here.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry).id(entry.id)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                .onChange(of: entries.count) { _, _ in proxy.scrollTo(entries.last?.id, anchor: .bottom) }
            }
        }
    }

    private func row(_ entry: PreviewConsoleEntry) -> some View {
        let location = entry.sourceLocation(workspaceRoot: appState.currentWorkspace.folderPath)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon(entry.level))
                .font(.system(size: 10))
                .foregroundColor(tint(entry.level))
                .frame(width: 14)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(entry.level.isProblem ? tint(entry.level) : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let location {
                Button {
                    appState.openInEditor(path: location.path, line: location.line)
                } label: {
                    Text("\((location.path as NSString).lastPathComponent):\(location.line)")
                        .font(.system(size: 10, design: .monospaced))
                        .underline()
                }
                .buttonStyle(.hitTestable)
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                .help("Open in the editor")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(entry.level.isProblem ? tint(entry.level).opacity(0.06) : Color.clear)
    }

    private func icon(_ level: PreviewConsoleEntry.Level) -> String {
        switch level {
        case .error, .exception: return "xmark.octagon.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .network, .resource: return "wifi.exclamationmark"
        case .info, .log, .debug: return "chevron.right"
        }
    }

    private func tint(_ level: PreviewConsoleEntry.Level) -> Color {
        switch level {
        case .error, .exception, .network, .resource: return .red
        case .warn: return .orange
        case .info, .log, .debug: return .secondary
        }
    }
}

private struct ServerLogView: View {
    @ObservedObject var server: DevServer

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(server.logTail(600))
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: server.logLines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
