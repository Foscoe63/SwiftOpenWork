import Foundation
import Network
import os
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// What the server needs from the app: which models it may offer, and a way to run one.
public protocol LocalAPIBackend: Sendable {
    func models() async -> [(id: String, owner: String)]
    /// Run the request, reporting chunks as they arrive. Throws `LocalAPIProtocol.Failure` for
    /// anything the client should see as an HTTP error.
    func generate(_ request: LocalAPIProtocol.Request, onChunk: @Sendable @escaping (LLMStreamChunk) -> Void) async throws
}

/// An OpenAI- and Anthropic-compatible HTTP server for the models this app runs.
///
/// Claude Code, Codex, OpenCode, Cline, editors and scripts all speak one of the two formats. Pointed
/// at this server they use the model already resident here (its KV cache, its scheduling — one
/// generation at a time, so they queue behind a chat turn instead of fighting it for memory),
/// rather than loading a second copy in another process.
///
/// Safe by construction, because anything that can reach a port can ask for tokens:
/// - **Loopback only**, never `0.0.0.0`.
/// - **A bearer token** on every request but `/health`: `Authorization: Bearer …` or `x-api-key`.
///   Compared in constant time. Generated once, kept in the Keychain.
/// - **No browser access.** A request carrying an `Origin` header is refused, and so is any `Host`
///   that is not a loopback name — closing the door on a web page or a DNS-rebinding trick that
///   would otherwise get your model to answer it.
/// - **Local models only** unless you opt in to cloud ones, so the token can't spend your API credits.
public final class LocalAPIServer: @unchecked Sendable {
    public static let shared = LocalAPIServer()
    public static let tokenKey = "local-api-token"
    public static let maxBodyBytes = 16 * 1024 * 1024

    public private(set) var port: UInt16 = 0
    public var isRunning: Bool { listener != nil }

    private var listener: NWListener?
    private var backend: LocalAPIBackend?
    private var token = ""
    private let queue = DispatchQueue(label: "SwiftOpenWork.LocalAPIServer")
    private let lock = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: NWConnection]())

    public init() {}

    // MARK: - Token

    /// The token clients present. Created on first use.
    public static func currentToken() -> String {
        if let existing = KeychainManager.shared.getSecret(forKey: tokenKey), !existing.isEmpty { return existing }
        return regenerateToken()
    }

    @discardableResult
    public static func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = "swo-" + bytes.map { String(format: "%02x", $0) }.joined()
        _ = KeychainManager.shared.saveSecret(token, forKey: tokenKey)
        return token
    }

    // MARK: - Lifecycle

    public func start(port requested: UInt16, token: String, backend: LocalAPIBackend) throws {
        stop()
        self.token = token
        self.backend = backend
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.port = requested
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        backend = nil
        let open = lock.withLock { held -> [NWConnection] in
            let all = Array(held.values)
            held.removeAll()
            return all
        }
        open.forEach { $0.cancel() }
        port = 0
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.withLock { $0[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.lock.withLock { $0[id] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    struct Head {
        var method: String
        var path: String
        var headers: [String: String]   // lowercased names
        var bodyOffset: Int
    }

    static func parseHead(_ data: Data) -> Head? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard let request = lines.first else { return nil }
        lines.removeFirst()
        let parts = request.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(parts[1])
        return Head(method: String(parts[0]).uppercased(), path: path, headers: headers, bodyOffset: end.upperBound)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let head = Self.parseHead(accumulated) {
                let length = Int(head.headers["content-length"] ?? "0") ?? 0
                if length > Self.maxBodyBytes {
                    self.send(connection, status: 413, body: LocalAPIProtocol.errorBody(.init(status: 413, message: "Request too large."), flavor: .openAI))
                    return
                }
                if accumulated.count - head.bodyOffset >= length {
                    let body = accumulated.subdata(in: head.bodyOffset..<(head.bodyOffset + length))
                    self.route(head, body: body, on: connection)
                    return
                }
            } else if accumulated.count > 64 * 1024 {
                connection.cancel()
                return
            }
            if error != nil || isComplete { connection.cancel(); return }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    // MARK: - Routing

    /// Why a request must be refused before anything is read from it, or nil.
    static func rejection(for head: Head, token: String) -> (status: Int, message: String)? {
        // A browser sends Origin on cross-site requests; no tool that is not a page does.
        if head.headers["origin"] != nil { return (403, "Browser requests are not accepted.") }
        if let host = head.headers["host"] {
            let name = host.hasPrefix("[") ? String(host.dropFirst().prefix { $0 != "]" }) : String(host.split(separator: ":").first ?? "")
            if !["localhost", "127.0.0.1", "::1"].contains(name.lowercased()) { return (403, "Requests must be addressed to localhost.") }
        }
        if head.path == "/health" { return nil }
        var presented = head.headers["x-api-key"] ?? ""
        if let authorization = head.headers["authorization"], authorization.lowercased().hasPrefix("bearer ") {
            presented = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard constantTimeEqual(presented, token), !token.isEmpty else { return (401, "Missing or wrong API key.") }
        return nil
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = x.count ^ y.count
        for index in 0..<max(x.count, y.count) {
            difference |= Int(index < x.count ? x[index] : 0) ^ Int(index < y.count ? y[index] : 0)
        }
        return difference == 0
    }

    private func route(_ head: Head, body: Data, on connection: NWConnection) {
        let flavor: LocalAPIProtocol.Flavor = head.path.hasPrefix("/v1/messages") || head.headers["anthropic-version"] != nil ? .anthropic : .openAI
        if let refusal = Self.rejection(for: head, token: token) {
            send(connection, status: refusal.status, body: LocalAPIProtocol.errorBody(.init(status: refusal.status, message: refusal.message), flavor: flavor))
            return
        }
        guard let backend else { connection.cancel(); return }
        switch (head.method, head.path) {
        case ("GET", "/health"):
            send(connection, status: 200, body: Data(#"{"status":"ok"}"#.utf8))
        case ("GET", "/v1/models"), ("GET", "/models"):
            Task {
                let models = await backend.models()
                self.send(connection, status: 200, body: LocalAPIProtocol.modelsList(models, flavor: flavor))
            }
        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            generate(body, flavor: .openAI, backend: backend, on: connection)
        case ("POST", "/v1/messages"):
            generate(body, flavor: .anthropic, backend: backend, on: connection)
        case ("POST", "/v1/messages/count_tokens"):
            let estimate = (try? LocalAPIProtocol.parse(body, flavor: .anthropic)).map { request in
                max(1, (request.system.count + request.messages.reduce(0) { $0 + $1.content.count }) / 4)
            } ?? 1
            send(connection, status: 200, body: Data(#"{"input_tokens":\#(estimate)}"#.utf8))
        case (_, "/v1/chat/completions"), (_, "/v1/messages"), (_, "/v1/models"):
            send(connection, status: 405, body: LocalAPIProtocol.errorBody(.init(status: 405, message: "Method not allowed."), flavor: flavor))
        default:
            send(connection, status: 404, body: LocalAPIProtocol.errorBody(.init(status: 404, message: "No such endpoint: \(head.path)"), flavor: flavor))
        }
    }

    // MARK: - Generation

    private func generate(_ body: Data, flavor: LocalAPIProtocol.Flavor, backend: LocalAPIBackend, on connection: NWConnection) {
        let request: LocalAPIProtocol.Request
        do { request = try LocalAPIProtocol.parse(body, flavor: flavor) } catch let failure as LocalAPIProtocol.Failure {
            send(connection, status: failure.status, body: LocalAPIProtocol.errorBody(failure, flavor: flavor)); return
        } catch { connection.cancel(); return }

        let task = Task {
            let accumulator = Accumulator()
            let responseId = (flavor == .openAI ? "chatcmpl-" : "msg_") + UUID().uuidString.prefix(12).lowercased()
            let modelName = request.model ?? "swiftopenwork"
            let streamer: Streamer? = request.stream ? Streamer(connection: connection, flavor: flavor, id: responseId, model: modelName, server: self) : nil
            do {
                try await backend.generate(request) { chunk in
                    accumulator.add(chunk)
                    streamer?.add(chunk)
                }
                if let streamer {
                    streamer.finish(accumulator.completion)
                } else {
                    let completion = accumulator.completion
                    let data = flavor == .openAI
                        ? LocalAPIProtocol.openAIResponse(id: responseId, model: modelName, completion)
                        : LocalAPIProtocol.anthropicResponse(id: responseId, model: modelName, completion)
                    self.send(connection, status: 200, body: data)
                }
            } catch let failure as LocalAPIProtocol.Failure {
                self.fail(connection, streamer: streamer, failure: failure, flavor: flavor)
            } catch is CancellationError {
                connection.cancel()
            } catch {
                self.fail(connection, streamer: streamer, failure: .init(status: 500, message: error.localizedDescription), flavor: flavor)
            }
        }
        // A client that hangs up stops the generation instead of leaving it to finish for no one.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                task.cancel()
                self?.lock.withLock { $0[ObjectIdentifier(connection)] = nil }
            default: break
            }
        }
    }

    private func fail(_ connection: NWConnection, streamer: Streamer?, failure: LocalAPIProtocol.Failure, flavor: LocalAPIProtocol.Flavor) {
        if let streamer, streamer.hasStarted {
            streamer.abort(failure)
        } else {
            send(connection, status: failure.status, body: LocalAPIProtocol.errorBody(failure, flavor: flavor))
        }
    }

    final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var value = LocalAPIProtocol.Completion()
        func add(_ chunk: LLMStreamChunk) {
            lock.lock(); defer { lock.unlock() }
            value.text += chunk.deltaText
            value.reasoning += chunk.deltaReasoning ?? ""
            value.toolCalls += chunk.toolCalls
            if let reason = chunk.finishReason { value.finishReason = reason }
            if let tokens = chunk.promptTokens { value.promptTokens = tokens }
            if let tokens = chunk.completionTokens { value.completionTokens = tokens }
        }
        var completion: LocalAPIProtocol.Completion { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Writes a streamed response as the chunks arrive.
    final class Streamer: @unchecked Sendable {
        private let connection: NWConnection
        private let flavor: LocalAPIProtocol.Flavor
        private let id: String
        private let model: String
        private unowned let server: LocalAPIServer
        private let lock = NSLock()
        private var started = false
        private var textBlockOpen = false
        private var blockIndex = 0
        private var toolIndex = 0

        init(connection: NWConnection, flavor: LocalAPIProtocol.Flavor, id: String, model: String, server: LocalAPIServer) {
            self.connection = connection; self.flavor = flavor; self.id = id; self.model = model; self.server = server
        }

        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }

        private func write(_ text: String, final: Bool = false) {
            // Plain sends are complete messages on a TCP stream; only the last one closes it.
            connection.send(content: Data(text.utf8), contentContext: final ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
        }

        private func begin() {
            guard !started else { return }
            started = true
            write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")
            switch flavor {
            case .openAI:
                write(LocalAPIProtocol.openAIFrame(id: id, model: model, delta: ["role": "assistant", "content": ""]))
            case .anthropic:
                write(LocalAPIProtocol.anthropicEvent("message_start", ["message": [
                    "id": id, "type": "message", "role": "assistant", "model": model, "content": [Any](),
                    "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": 0, "output_tokens": 0],
                ] as [String: Any]]))
            }
        }

        func add(_ chunk: LLMStreamChunk) {
            lock.lock(); defer { lock.unlock() }
            begin()
            switch flavor {
            case .openAI:
                if !chunk.deltaText.isEmpty { write(LocalAPIProtocol.openAIFrame(id: id, model: model, delta: ["content": chunk.deltaText])) }
                if let reasoning = chunk.deltaReasoning, !reasoning.isEmpty {
                    write(LocalAPIProtocol.openAIFrame(id: id, model: model, delta: ["reasoning_content": reasoning]))
                }
                for call in chunk.toolCalls {
                    write(LocalAPIProtocol.openAIFrame(id: id, model: model, delta: LocalAPIProtocol.openAIToolCallDelta(call, index: toolIndex)))
                    toolIndex += 1
                }
            case .anthropic:
                if !chunk.deltaText.isEmpty {
                    if !textBlockOpen {
                        write(LocalAPIProtocol.anthropicEvent("content_block_start", ["index": blockIndex, "content_block": ["type": "text", "text": ""]]))
                        textBlockOpen = true
                    }
                    write(LocalAPIProtocol.anthropicEvent("content_block_delta", ["index": blockIndex, "delta": ["type": "text_delta", "text": chunk.deltaText]]))
                }
                for call in chunk.toolCalls {
                    if textBlockOpen { write(LocalAPIProtocol.anthropicEvent("content_block_stop", ["index": blockIndex])); blockIndex += 1; textBlockOpen = false }
                    write(LocalAPIProtocol.anthropicEvent("content_block_start", ["index": blockIndex, "content_block": ["type": "tool_use", "id": call.id, "name": call.toolName, "input": [String: Any]()]]))
                    write(LocalAPIProtocol.anthropicEvent("content_block_delta", ["index": blockIndex, "delta": ["type": "input_json_delta", "partial_json": call.argumentsJson]]))
                    write(LocalAPIProtocol.anthropicEvent("content_block_stop", ["index": blockIndex]))
                    blockIndex += 1
                }
            }
        }

        func finish(_ completion: LocalAPIProtocol.Completion) {
            lock.lock(); defer { lock.unlock() }
            begin()
            switch flavor {
            case .openAI:
                write(LocalAPIProtocol.openAIFrame(id: id, model: model, delta: [:], finish: completion.openAIFinish, usage: completion))
                write(LocalAPIProtocol.openAIDone, final: true)
            case .anthropic:
                if textBlockOpen { write(LocalAPIProtocol.anthropicEvent("content_block_stop", ["index": blockIndex])) }
                write(LocalAPIProtocol.anthropicEvent("message_delta", [
                    "delta": ["stop_reason": completion.anthropicStop, "stop_sequence": NSNull()],
                    "usage": ["output_tokens": completion.completionTokens],
                ]))
                write(LocalAPIProtocol.anthropicEvent("message_stop", [:]), final: true)
            }
        }

        func abort(_ failure: LocalAPIProtocol.Failure) {
            lock.lock(); defer { lock.unlock() }
            switch flavor {
            case .openAI: write("data: " + String(decoding: LocalAPIProtocol.errorBody(failure, flavor: .openAI), as: UTF8.self) + "\n\n" + LocalAPIProtocol.openAIDone, final: true)
            case .anthropic: write("event: error\ndata: " + String(decoding: LocalAPIProtocol.errorBody(failure, flavor: .anthropic), as: UTF8.self) + "\n\n", final: true)
            }
        }
    }

    // MARK: - Plain responses

    private func send(_ connection: NWConnection, status: Int, body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        head += String(decoding: body, as: UTF8.self)
        connection.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }
}
