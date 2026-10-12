import Foundation

/// Run a program to completion with a deadline, capturing what it prints.
///
/// For the short helper processes the app starts itself — hooks, `gh`, `git push` — as opposed to
/// the agent's shell, which has its own runner. Whatever the program started is stopped with it
/// when the deadline passes, and a program that never reads stdin cannot stall us on a full pipe.
public enum SubprocessRunner {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    public static let maxCapturedBytes = 256 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        stdin: Data? = nil,
        timeout: TimeInterval,
        maxBytes: Int = maxCapturedBytes
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.environment = environment

            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe

            let box = Capture(limit: maxBytes)
            outPipe.fileHandleForReading.readabilityHandler = { box.appendOut($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { box.appendErr($0.availableData) }

            let once = Once()
            let complete: @Sendable (Bool) -> Void = { timedOut in
                guard once.claim() else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                box.appendOut(outPipe.fileHandleForReading.availableData)
                box.appendErr(errPipe.fileHandleForReading.availableData)
                let captured = box.snapshot()
                continuation.resume(returning: Result(
                    exitCode: timedOut ? -1 : process.terminationStatus,
                    stdout: captured.out, stderr: captured.err, timedOut: timedOut
                ))
            }
            process.terminationHandler = { _ in complete(false) }
            do {
                try process.run()
            } catch {
                _ = once.claim()
                continuation.resume(returning: Result(exitCode: 127, stdout: "", stderr: "could not start: \(error.localizedDescription)", timedOut: false))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                try? inPipe.fileHandleForWriting.close()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                ProcessTree.terminate(process.processIdentifier, grace: 1)
                complete(true)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var out = Data(), err = Data()
        init(limit: Int) { self.limit = limit }
        func appendOut(_ data: Data) { append(data, toOut: true) }
        func appendErr(_ data: Data) { append(data, toOut: false) }
        private func append(_ data: Data, toOut: Bool) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if toOut {
                if out.count < limit { out.append(data.prefix(limit - out.count)) }
            } else if err.count < limit {
                err.append(data.prefix(limit - err.count))
            }
        }
        func snapshot() -> (out: String, err: String) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }
    }
}
