import Foundation

/// JSON-RPC 2.0 over a child process's stdin/stdout, one JSON object per line: the transport of
/// the Agent Client Protocol (https://agentclientprotocol.com).
///
/// This class knows nothing about ACP's methods. It sends requests and matches their responses,
/// and hands everything the agent initiates — notifications and requests — to `onIncoming`, in
/// the order it arrived.
public final class ACPConnection: @unchecked Sendable {

    public enum Incoming: @unchecked Sendable {
        case notification(method: String, params: [String: Any])
        /// The agent is asking us something and waits for `reply`.
        case request(method: String, params: [String: Any], reply: @Sendable (_ result: Any?, _ error: (code: Int, message: String)?) -> Void)
        /// The process ended.
        case closed(reason: String)
    }

    public struct RemoteError: Error, LocalizedError, @unchecked Sendable {
        public var code: Int
        public var message: String
        public var errorDescription: String? { message }
    }

    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let lock = NSLock()
    private var nextId = 1
    private struct Box: @unchecked Sendable { var value: [String: Any] }
    private var pending: [Int: CheckedContinuation<Box, Error>] = [:]
    private var buffer = Data()
    private var stderrTail = Data()
    private var closedReason: String?
    private var onIncoming: (@Sendable (Incoming) -> Void)?

    public init(executable: String, arguments: [String], cwd: String, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// What the program wrote to stderr lately; the first thing to read when it fails to start.
    public var recentStandardError: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start(onIncoming: @escaping @Sendable (Incoming) -> Void) throws {
        self.onIncoming = onIncoming
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.received(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 8_192 { self.stderrTail = self.stderrTail.suffix(8_192) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            self?.finished(status: process.terminationStatus)
        }
        try process.run()
    }

    func setIncomingHandler(_ handler: @escaping @Sendable (Incoming) -> Void) {
        lock.lock(); onIncoming = handler; lock.unlock()
    }

    // MARK: - Sending

    public func request(_ method: String, _ params: [String: Any], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let id: Int = lock.withLockReturning {
            defer { nextId += 1 }
            return nextId
        }
        let timeoutTask = timeout.map { seconds in
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.fail(id: id, with: RemoteError(code: -32001, message: "\(method) timed out after \(Int(seconds))s"))
            }
        }
        defer { timeoutTask?.cancel() }
        let box: Box = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let closedReason {
                lock.unlock()
                continuation.resume(throwing: RemoteError(code: -32000, message: closedReason))
                return
            }
            pending[id] = continuation
            lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
        return box.value
    }

    public func notify(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func respond(id: Any, result: Any?, error: (code: Int, message: String)?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { message["error"] = ["code": error.code, "message": error.message] }
        else { message["result"] = result ?? NSNull() }
        write(message)
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        // A write to a dead pipe raises SIGPIPE-style errors through the API; ignoring is right,
        // since the termination handler already fails what is waiting.
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - Receiving

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            dispatch(object)
        }
    }

    private func dispatch(_ object: [String: Any]) {
        let method = object["method"] as? String
        let id = object["id"]
        if let method {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id {
                // Only numbers and strings are valid ids; keep it as JSON text to cross the closure.
                let idJSON = (try? JSONSerialization.data(withJSONObject: [id])).map { String(decoding: $0, as: UTF8.self) } ?? "[0]"
                onIncoming?(.request(method: method, params: params, reply: { [weak self] result, error in
                    let id = (try? JSONSerialization.jsonObject(with: Data(idJSON.utf8)) as? [Any])?.first ?? 0
                    self?.respond(id: id, result: result, error: error)
                }))
            } else {
                onIncoming?(.notification(method: method, params: params))
            }
            return
        }
        guard let numeric = (id as? Int) ?? (id as? Double).map(Int.init) else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: numeric)
        lock.unlock()
        if let error = object["error"] as? [String: Any] {
            continuation?.resume(throwing: RemoteError(code: error["code"] as? Int ?? -32603, message: error["message"] as? String ?? "agent error"))
        } else {
            continuation?.resume(returning: Box(value: object["result"] as? [String: Any] ?? [:]))
        }
    }

    private func fail(id: Int, with error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func finished(status: Int32) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Whatever it printed last may still be buffered.
        received(stdoutPipe.fileHandleForReading.availableData)
        let tail = recentStandardError
        let reason = "The agent exited (status \(status))." + (tail.isEmpty ? "" : "\n" + String(tail.suffix(600)))
        lock.lock()
        closedReason = reason
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in waiting { continuation.resume(throwing: RemoteError(code: -32000, message: reason)) }
        onIncoming?(.closed(reason: reason))
    }

    public func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { ProcessTree.terminate(process.processIdentifier, grace: 2) }
    }
}

private extension NSLock {
    func withLockReturning<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
