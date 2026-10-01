import SwiftUI
import AppKit
import SwiftTerm
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkEngine

/// Owns the live shell so it outlives the Terminal tab.
///
/// A SwiftUI view that built its own terminal would kill the shell, and any long-running program
/// in it, whenever the user switched to another inspector tab. The view and the process live here;
/// the tab only displays them.
@MainActor
final class InteractiveTerminalHost: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = InteractiveTerminalHost()

    @Published private(set) var isRunning = false
    @Published private(set) var title = ""
    @Published private(set) var exitNote: String?

    private(set) lazy var terminalView: LocalProcessTerminalView = {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return view
    }()

    private var startedIn: String?

    /// Start the shell if there is none. `directory` is where it opens; later calls leave a
    /// running shell alone, since changing the workspace should not close the user's session.
    func ensureStarted(directory: String) {
        guard !isRunning else { return }
        start(directory: directory)
    }

    func restart(directory: String) {
        terminate()
        terminalView.terminal.resetToInitialState()
        start(directory: directory)
    }

    private func start(directory: String) {
        let settings = PersistenceManager.shared.loadSettings()
        let shell = settings.terminalShell.isEmpty ? "/bin/zsh" : settings.terminalShell
        var environment = ToolExecutionEngine.defaultEnvironment(custom: settings.customEnvironmentVariables)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let resolved = (directory as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: resolved)
        terminalView.startProcess(
            executable: shell,
            // A login shell, so PATH and the user's own setup match what Terminal.app gives them.
            args: ["-l"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: exists ? resolved : NSHomeDirectory()
        )
        startedIn = resolved
        exitNote = nil
        isRunning = true
    }

    func terminate() {
        guard isRunning else { return }
        PTYProcess.terminateGroup(of: terminalView)
        isRunning = false
    }

    /// Type `text` into the shell, as if pasted. A trailing newline runs it.
    func send(_ text: String) {
        guard isRunning else { return }
        terminalView.send(txt: text)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.title = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.isRunning = false
            self.exitNote = PTYExitStatus.normalize(exitCode).map { $0 == 0 ? "Shell exited." : "Shell exited with code \($0)." } ?? "Shell closed."
        }
    }
}

/// Displays the shared terminal view. Returning the same `NSView` each time is the point: it keeps
/// the scrollback and the running process across tab switches.
struct InteractiveTerminalRepresentable: NSViewRepresentable {
    let host: InteractiveTerminalHost
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(host.terminalView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if host.terminalView.superview !== container { attach(host.terminalView, to: container) }
    }

    private func attach(_ view: NSView, to container: NSView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

/// The Terminal tab's interactive mode: a real PTY, so programs that prompt, page or take over the
/// screen (`npm init`, `ssh`, `python`, `vim`, `top`) work, which a line-at-a-time runner cannot do.
struct InteractiveTerminalView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var host = InteractiveTerminalHost.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(host.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(host.title.isEmpty ? (host.isRunning ? "Shell" : "Not running") : host.title)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .lineLimit(1)
                Spacer()
                if let note = host.exitNote {
                    Text(note).font(.system(size: 10)).foregroundColor(.orange)
                }
                Button(host.isRunning ? "Restart" : "Start") {
                    host.restart(directory: appState.currentWorkspace.folderPath)
                }
                .controlSize(.small)
                if host.isRunning {
                    Button("Stop", role: .destructive) { host.terminate() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            InteractiveTerminalRepresentable(host: host, theme: appState.settings.theme)
        }
        .onAppear { host.ensureStarted(directory: appState.currentWorkspace.folderPath) }
    }
}
