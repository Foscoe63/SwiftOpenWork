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

/// A terminal view that tells its owner when its process has exited, and sizes itself generously
/// so wrapped output is not cut at 80 columns while no window is showing it.
final class AgentCommandTerminalView: LocalProcessTerminalView {
    var onExit: ((Int32?) -> Void)?

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onExit?(PTYExitStatus.normalize(exitCode))
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

/// Runs agent commands that asked to be interactive, one at a time, in a terminal the user can
/// watch and type into. The Terminal tab shows the current one.
///
/// One at a time because there is one place to look and one keyboard: two prompts racing for the
/// same input would have the user answering the wrong one.
@MainActor
final class AgentTerminalHost: NSObject, ObservableObject, InteractiveCommandRunner {
    static let shared = AgentTerminalHost()

    @Published private(set) var terminalView: AgentCommandTerminalView?
    @Published private(set) var title = ""
    @Published private(set) var isRunning = false
    @Published private(set) var queued = 0

    private var tail: Task<Void, Never> = Task {}

    nonisolated func run(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        displayCommand: String,
        timeoutSeconds: TimeInterval
    ) async -> InteractiveCommandResult {
        await self.enqueue(
            executable: executable, arguments: arguments, cwd: cwd, environment: environment,
            displayCommand: displayCommand, timeoutSeconds: timeoutSeconds
        )
    }

    private func enqueue(
        executable: String, arguments: [String], cwd: String, environment: [String: String],
        displayCommand: String, timeoutSeconds: TimeInterval
    ) async -> InteractiveCommandResult {
        queued += 1
        let previous = tail
        let job = Task { @MainActor () -> InteractiveCommandResult in
            await previous.value
            self.queued -= 1
            return await self.runOne(
                executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                displayCommand: displayCommand, timeoutSeconds: timeoutSeconds
            )
        }
        tail = Task { _ = await job.value }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func runOne(
        executable: String, arguments: [String], cwd: String, environment: [String: String],
        displayCommand: String, timeoutSeconds: TimeInterval
    ) async -> InteractiveCommandResult {
        if Task.isCancelled { return InteractiveCommandResult(output: "", exitCode: nil, cancelled: true) }

        let view = AgentCommandTerminalView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView = view
        title = displayCommand
        isRunning = true
        reveal()

        let exists = FileManager.default.fileExists(atPath: cwd)
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32?, Bool, Bool), Never>) in
            var finished = false
            func finish(_ code: Int32?, timedOut: Bool, cancelled: Bool) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: (code, timedOut, cancelled))
            }
            view.onExit = { code in finish(code, timedOut: false, cancelled: false) }
            view.startProcess(
                executable: executable,
                args: arguments,
                environment: environment.map { "\($0.key)=\($0.value)" },
                execName: nil,
                currentDirectory: exists ? cwd : NSHomeDirectory()
            )
            // A person has to answer, so the limit is generous, but a prompt nobody ever comes
            // back to must not hold the agent forever.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if !finished { view.terminate(); finish(nil, timedOut: true, cancelled: false) }
            }
            // The turn was stopped: end the process rather than leave it waiting for input.
            Task { @MainActor in
                while !finished, !Task.isCancelled { try? await Task.sleep(nanoseconds: 250_000_000) }
                if !finished { view.terminate(); finish(nil, timedOut: false, cancelled: true) }
            }
        }

        // The last bytes of output and the exit notice are delivered separately; let both land.
        try? await Task.sleep(nanoseconds: 150_000_000)
        isRunning = false
        return InteractiveCommandResult(
            output: view.transcript(), exitCode: outcome.0, timedOut: outcome.1, cancelled: outcome.2
        )
    }

    /// Bring the agent's terminal to the front: this is a command waiting for the user.
    private func reveal() {
        UserDefaults.standard.set(TerminalMode.agent.rawValue, forKey: TerminalMode.storageKey)
        AppState.shared.revealInspector(tab: .terminal, minimumWidth: 480)
    }

    /// Stop the running command, as the Stop button does.
    func stop() {
        terminalView?.terminate()
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
                if host.queued > 0 {
                    Text("\(host.queued) waiting").font(.system(size: 10)).foregroundColor(.orange)
                }
                if host.isRunning {
                    Text("Type here to answer").font(.system(size: 10)).foregroundColor(.orange)
                    Button("Stop", role: .destructive) { host.stop() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if let view = host.terminalView {
                AgentTerminalRepresentable(view: view)
            } else {
                Text("Commands the agent runs with `interactive: true` appear here, so you can answer their prompts.")
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
