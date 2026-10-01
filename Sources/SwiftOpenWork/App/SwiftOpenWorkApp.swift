import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead MCP child stdin must not abort the process (EPIPE).
        signal(SIGPIPE, SIG_IGN)

        if let image = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = image
        } else if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "AppIcon.icns", withExtension: nil),
                  let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }

        WindowLayoutStore.observeMainWindowAutosave()
        // Window may not exist yet; configure now and again on the next runloop.
        WindowLayoutStore.configureMainWindowAutosave()
        DispatchQueue.main.async {
            WindowLayoutStore.configureMainWindowAutosave()
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        WindowLayoutStore.configureMainWindowAutosave()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // A dev server outliving the app would hold its port with nothing left to stop it.
        MainActor.assumeIsolated { DevServerManager.shared.terminateAllNow() }
        // Same for a `splash serve` process SwiftOpenWork launched — it is not the user's to clean up.
        MainActor.assumeIsolated { SplashServerManager.shared.terminateNow() }
        for window in NSApp.windows where window.styleMask.contains(.titled) && window.styleMask.contains(.resizable) {
            WindowLayoutStore.saveWindowFrame(from: window)
        }
        AppIdentity.defaults.synchronize()
        // Chat history is written in the background; the last reply must reach disk.
        PersistenceManager.shared.flushSessionWrites()
        // A reply still generating on the GPU would crash the process as `exit` tears MLX down.
        NativeMLXService.shared.prepareForExit()
        // Language servers would exit on their own when stdin closes; this makes it certain.
        LiveConnections.terminateAll()
        // ai-memory: flush a session-end for any open sessions while we still can.
        AIMemoryHooks.shared.flushOnTerminate()
    }
}

@main
public struct SwiftOpenWorkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    public init() {
        LocalInferenceWiring.install()
        LegacyIdentityMigration.runIfNeeded()
    }

    public var body: some Scene {
        WindowGroup {
            MainView(appState: appState)
                .preferredColorScheme(colorScheme(for: appState.settings.theme))
                .background(WindowFramePersistenceInstaller())
                .onAppear {
                    // Schedules only exist if something is watching the clock. Started here
                    // rather than in `AppDelegate` because it needs the populated `AppState`.
                    AutomationScheduler.shared.start(appState: appState)
                    LoopRunner.shared.startScheduler(appState: appState)
                    // Connect MCP servers now, in the background, so the first turn — and the first
                    // scheduled run — has their tools instead of being told they are still warming.
                    if !AppIdentity.isHostedByTests {
                        Task { await MCPClientManager.shared.warmAllInBackground(perServerTimeout: .seconds(45)) }
                    }
                    UpdateChecker.runAutomaticCheckIfDue(appState: appState)
                    WindowLayoutStore.observeMainWindowAutosave()
                    // Delay so SwiftUI finishes applying its initial frame first, then we override.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        WindowLayoutStore.configureMainWindowAutosave()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        WindowLayoutStore.configureMainWindowAutosave()
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()

            CommandGroup(after: .windowArrangement) {
                Button("Move \(appState.inspectorTab.title) to Its Own Window") {
                    openWindow(id: "pane", value: appState.inspectorTab)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
            }

            // Find (⌘F), Find Next and Use Selection for Find, which reach the editor's find bar.
            TextEditingCommands()

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    guard let document = EditorWorkspace.shared.activeDocument else { return }
                    do {
                        try document.save()
                    } catch {
                        appState.showToast(error.localizedDescription)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save All") {
                    if let failure = EditorWorkspace.shared.saveAll().first {
                        appState.showToast("\(failure.fileName): \(failure.reason)")
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    appState.createNewSession()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Command Palette…") {
                    appState.isSearchDialogOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Find in Project…") {
                    appState.showProjectSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Show Editor") {
                    if appState.navigationDestination != .chat && appState.navigationDestination != .tools {
                        appState.navigationDestination = .chat
                    }
                    appState.revealInspector(tab: .editor, minimumWidth: 560)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Show Preview") {
                    if appState.navigationDestination != .chat && appState.navigationDestination != .tools {
                        appState.navigationDestination = .chat
                    }
                    appState.revealInspector(tab: .preview, minimumWidth: 560)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            // The preview's tabs and layout, reachable from the keyboard as well as the pane.
            CommandMenu("Preview") {
                Button("New Preview Tab") {
                    PreviewSessions.shared.newTab(workspaceRoot: appState.currentWorkspace.folderPath)
                    appState.revealInspector(tab: .preview, minimumWidth: 560)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button("Duplicate Preview Tab") {
                    let sessions = PreviewSessions.shared
                    sessions.duplicate(sessions.active.id)
                    appState.revealInspector(tab: .preview, minimumWidth: 560)
                }

                Button("Close Preview Tab") {
                    let sessions = PreviewSessions.shared
                    sessions.close(sessions.active.id)
                }

                Divider()

                Button("One Preview at a Time") { PreviewSessions.shared.layout = .single }
                Button("Previews Side by Side") {
                    PreviewSessions.shared.layout = .sideBySide
                    appState.revealInspector(tab: .preview, minimumWidth: 900)
                }
                Button("Previews Stacked") {
                    PreviewSessions.shared.layout = .stacked
                    appState.revealInspector(tab: .preview, minimumWidth: 560)
                }
            }

            CommandMenu("Navigation") {
                Button("Chat & Sessions") {
                    appState.navigationDestination = .chat
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("AI Agents") {
                    appState.navigationDestination = .agents
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Model Providers") {
                    appState.navigationDestination = .providers
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Automations") {
                    appState.navigationDestination = .automations
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Settings") {
                    appState.navigationDestination = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // A pane torn off the inspector: the editor, preview, sub-agent tree or terminal in a
        // window of its own, for a second display. One window per pane; opening it again focuses it.
        WindowGroup("Pane", id: "pane", for: InspectorTab.self) { $tab in
            if let tab {
                DetachedPaneWindow(appState: appState, tab: tab)
                    .preferredColorScheme(colorScheme(for: appState.settings.theme))
            }
        }
        .defaultSize(width: 760, height: 560)

        MenuBarExtra(isInserted: Binding(
            get: { appState.settings.showMenuBarMonitor },
            // MenuBarExtra writes this binding back while SwiftUI is updating views (and when the
            // user drags the item out of the menu bar). Publishing from inside that update
            // loops forever, so only a real change is written, and not in the update's stack.
            set: { newValue in
                guard appState.settings.showMenuBarMonitor != newValue else { return }
                DispatchQueue.main.async {
                    appState.settings.showMenuBarMonitor = newValue
                    appState.updateSettings(appState.settings)
                }
            }
        )) {
            MenuBarMonitorView(appState: appState)
        } label: {
            Image(systemName: appState.isGenerating || !appState.backgroundRuns.isEmpty
                  ? "bolt.circle.fill" : "bolt.circle")
        }
        .menuBarExtraStyle(.window)
    }

    @Environment(\.openWindow) private var openWindow

    private func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .light: return .light
        case .dark, .midnight, .cyberpunk, .monokai: return .dark
        case .system: return nil
        }
    }
}
