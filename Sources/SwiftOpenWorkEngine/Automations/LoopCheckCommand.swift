import Foundation
import SwiftOpenWorkCore

/// Runs the shell command a loop step or goal is checked by. Never throws and never judges: the
/// verdict is read by `LoopRules.readCommandVerdict`, which is pure and tested.
///
/// `bash -lc`, the same shell the agent's own command tool uses. A check that behaves differently
/// from the command the user pasted it from is a check nobody can trust — `npm test` has to mean
/// what it means in their terminal, login profile and PATH included.
public enum LoopCheckCommand {

    /// Shorter than the agent's own command cap on purpose: a check is meant to be a test suite or
    /// a file test, not the work, and a loop is waiting on it, sometimes with nobody watching.
    public static let timeoutSeconds = 120

    public static func run(_ command: String, in folder: String, timeout: Int = timeoutSeconds) async -> LoopRules.CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(command, in: folder, timeout: timeout))
            }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        /// A check that prints without end must not grow the app without end. The tail is what
        /// the retry needs: a test runner prints its summary last.
        private let cap = 200_000
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            if data.count > cap { data = data.suffix(cap) }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    static func runBlocking(_ command: String, in folder: String, timeout: Int) -> LoopRules.CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue
        process.currentDirectoryURL = URL(fileURLWithPath: exists ? folder : NSHomeDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let buffer = Buffer()
        let endOfOutput = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                endOfOutput.signal()
                return
            }
            buffer.append(chunk)
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .init(exitCode: nil, output: "", spawnError: error.localizedDescription)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            timedOut = true
            // The whole tree, not just the shell: `npm test` and its children keep running (and
            // keep the pipe open) when only `bash` is signalled. See `ProcessTree.terminate`.
            ProcessTree.terminate(process.processIdentifier)
            _ = finished.wait(timeout: .now() + .seconds(4))
        }
        // What was written just before exit gets a moment to arrive, but never an unbounded wait:
        // a background process that survived still holds the write end open, and reading to end of
        // file then blocks for as long as it lives — which stalled the loop, and the schedule
        // behind it, for good.
        _ = endOfOutput.wait(timeout: .now() + 1.5)
        pipe.fileHandleForReading.readabilityHandler = nil

        return .init(
            exitCode: timedOut ? nil : process.terminationStatus,
            output: buffer.text,
            timedOut: timedOut,
            timeoutSeconds: timeout
        )
    }
}
