import SwiftUI
import AppKit
import SwiftTerm
import SwiftOpenWorkEngine

/// SwiftTerm reports a child's raw `wait` status, so `exit 3` arrives as 768. Callers and models
/// expect 3, and 128 + signal for a process that was killed.
enum PTYExitStatus {
    static func normalize(_ raw: Int32?) -> Int32? {
        guard let raw else { return nil }
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }
}

/// Ending a PTY child properly. SwiftTerm's `terminate()` signals only the shell and cancels its
/// own exit monitor, so a command the shell started (`sleep`, a dev server) would be orphaned and
/// no exit would ever be reported.
enum PTYProcess {
    /// SIGTERM to the shell's whole process group, then SIGKILL if anything is still there after
    /// `grace`. The shell leads its own session, so its pid is the group id.
    @MainActor
    static func terminateGroup(of view: LocalProcessTerminalView, grace: TimeInterval = 2) {
        let pid = view.process.shellPid
        if pid > 0 {
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                // ESRCH means it is gone, which is the outcome we wanted.
                kill(-pid, SIGKILL)
            }
        }
        view.terminate()
    }
}

/// A terminal view that reports its activity and exit to its owner, and is sized generously so
/// wrapped output is not cut at 80 columns while no window is showing it.
final class AgentCommandTerminalView: LocalProcessTerminalView {
    var onExit: ((Int32?) -> Void)?
    /// Output arrived, or the user typed. A quiet terminal is how "waiting for input" is detected.
    var onActivity: (() -> Void)?

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onExit?(PTYExitStatus.normalize(exitCode))
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onActivity?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        onActivity?()
    }

    /// Everything the terminal currently holds, scrollback included, as the user would read it.
    func transcript() -> String {
        String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One interactive command, from launch to exit. It outlives the tool call that started it: the
/// call returns when the command goes quiet, and later `send_input` calls continue it.
@MainActor
final class AgentTerminalSession {
    let view: AgentCommandTerminalView
    let command: String
    private(set) var exitCode: Int32?
    private(set) var exited = false
    private(set) var timedOut = false
    private(set) var lastActivity = Date()
    /// How much of the transcript earlier calls already returned, so each call reports only news.
    private var returnedTranscript = ""
    private var lifetime: Task<Void, Never>?

    init(view: AgentCommandTerminalView, command: String) {
        self.view = view
        self.command = command
        view.onActivity = { [weak self] in
            // Output and keystrokes arrive on the main thread.
            MainActor.assumeIsolated { self?.lastActivity = Date() }
        }
        view.onExit = { [weak self] code in
            MainActor.assumeIsolated {
                self?.exitCode = code
                self?.exited = true
                self?.lifetime?.cancel()
            }
        }
    }

    func start(executable: String, arguments: [String], cwd: String, environment: [String: String], limit: TimeInterval) {
        let exists = FileManager.default.fileExists(atPath: cwd)
        view.startProcess(
            executable: executable, args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: nil, currentDirectory: exists ? cwd : NSHomeDirectory()
        )
        // A person has to answer, so the limit is generous, but a prompt nobody returns to must
        // not leave a process running forever.
        lifetime = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.exited else { return }
            self.timedOut = true
            self.terminate()
        }
    }

    func type(_ text: String) {
        lastActivity = Date()
        view.send(txt: text)
    }

    /// End the command. SwiftTerm will not report an exit after `terminate()`, so record one here:
    /// 128 + SIGTERM, the status a shell would show.
    func terminate() {
        guard !exited else { return }
        PTYProcess.terminateGroup(of: view)
        exitCode = exitCode ?? 143
        exited = true
        lifetime?.cancel()
    }

    /// Wait until the command exits, or has been quiet for `idle`. Cancelling the caller (the
    /// turn was stopped) ends the command too, rather than leaving it waiting on nobody.
    func settle(idle: TimeInterval) async -> Bool {
        let waitStart = Date()
        while !exited {
            if Task.isCancelled { terminate(); break }
            if Date().timeIntervalSince(max(lastActivity, waitStart)) >= idle { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // The last bytes and the exit notice are delivered separately; let both land.
        try? await Task.sleep(nanoseconds: 150_000_000)
        return true
    }

    /// What the terminal showed since the previous call.
    func newOutput() -> String {
        let now = view.transcript()
        defer { returnedTranscript = now }
        if now.hasPrefix(returnedTranscript) {
            return String(now.dropFirst(returnedTranscript.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A full-screen program redrew in place; the honest report is the whole screen.
        return now
    }

    func result(finished: Bool, cancelled: Bool) -> InteractiveCommandResult {
        InteractiveCommandResult(
            output: newOutput(), exitCode: finished ? exitCode : nil, timedOut: timedOut,
            cancelled: cancelled && !timedOut, stillRunning: !finished
        )
    }
}

/// Runs agent commands that asked to be interactive in a terminal the user can watch and type
/// into, and lets the agent keep answering them. The Terminal tab shows the current session.
///
/// One session at a time: there is one place to look and one keyboard, and two prompts racing for
/// it would have the user answering the wrong one.
@MainActor
final class AgentTerminalHost: NSObject, ObservableObject, InteractiveCommandRunner {
    static let shared = AgentTerminalHost()

    @Published private(set) var terminalView: AgentCommandTerminalView?
    @Published private(set) var title = ""
    @Published private(set) var isRunning = false

    private var session: AgentTerminalSession?
    private var watcher: Task<Void, Never>?

    nonisolated func run(
        executable: String, arguments: [String], cwd: String, environment: [String: String],
        displayCommand: String, timeoutSeconds: TimeInterval, idleSeconds: TimeInterval
    ) async -> InteractiveCommandResult {
        await start(
            executable: executable, arguments: arguments, cwd: cwd, environment: environment,
            displayCommand: displayCommand, timeoutSeconds: timeoutSeconds, idleSeconds: idleSeconds
        )
    }

    nonisolated func sendInput(_ input: String, idleSeconds: TimeInterval, terminate: Bool) async -> InteractiveCommandResult {
        await continueSession(input: input, idleSeconds: idleSeconds, terminate: terminate)
    }

    private func start(
        executable: String, arguments: [String], cwd: String, environment: [String: String],
        displayCommand: String, timeoutSeconds: TimeInterval, idleSeconds: TimeInterval
    ) async -> InteractiveCommandResult {
        if let live = session, !live.exited {
            return InteractiveCommandResult(
                output: "", exitCode: nil,
                refusal: "An interactive command is still running (`\(live.command)`). Answer it with send_input, or end it with send_input terminate:true, before starting another."
            )
        }
        if Task.isCancelled { return InteractiveCommandResult(output: "", exitCode: nil, cancelled: true) }

        let view = AgentCommandTerminalView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let created = AgentTerminalSession(view: view, command: displayCommand)
        session = created
        terminalView = view
        title = displayCommand
        isRunning = true
        reveal()
        watch(created)
        created.start(executable: executable, arguments: arguments, cwd: cwd, environment: environment, limit: timeoutSeconds)
        return await finishCall(created, idle: idleSeconds)
    }

    private func continueSession(input: String, idleSeconds: TimeInterval, terminate: Bool) async -> InteractiveCommandResult {
        guard let live = session, !live.exited else {
            return InteractiveCommandResult(
                output: "", exitCode: nil,
                refusal: "No interactive command is running. Start one with terminal_command interactive:true."
            )
        }
        if terminate { live.terminate() } else { live.type(input) }
        return await finishCall(live, idle: idleSeconds)
    }

    private func finishCall(_ live: AgentTerminalSession, idle: TimeInterval) async -> InteractiveCommandResult {
        let finished = await live.settle(idle: idle)
        let cancelled = Task.isCancelled
        if live.exited, session === live { isRunning = false }
        return live.result(finished: finished, cancelled: cancelled)
    }

    /// Keep `isRunning` true until this session's process ends, even after the call that started
    /// it has returned.
    private func watch(_ live: AgentTerminalSession) {
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while !live.exited, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard let self, self.session === live else { return }
            self.isRunning = false
        }
    }

    /// Bring the agent's terminal to the front: this is a command waiting for the user.
    private func reveal() {
        UserDefaults.standard.set(TerminalMode.agent.rawValue, forKey: TerminalMode.storageKey)
        AppState.shared.revealInspector(tab: .terminal, minimumWidth: 480)
    }

    /// Stop the running command, as the Stop button does.
    func stop() {
        session?.terminate()
    }
}

enum TerminalMode: String {
    case interactive, agent, log
    static let storageKey = "terminal.mode"
}

/// The Terminal tab's Agent mode: the live (or last) agent command, with the keyboard connected.
struct AgentTerminalView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var host = AgentTerminalHost.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(host.isRunning ? Color.orange : Color.secondary).frame(width: 7, height: 7)
                Text(host.title.isEmpty ? "No agent command yet" : host.title)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if host.isRunning {
                    Text("Waiting? Type here, or let the agent answer").font(.system(size: 10)).foregroundColor(.orange)
                    Button("Stop", role: .destructive) { host.stop() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if let view = host.terminalView {
                AgentTerminalRepresentable(view: view)
            } else {
                Text("Commands the agent runs with `interactive: true` appear here. You can answer their prompts, or let the agent do it with send_input.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        }
    }
}

struct AgentTerminalRepresentable: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
