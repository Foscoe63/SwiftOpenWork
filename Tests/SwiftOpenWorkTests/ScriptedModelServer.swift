import Foundation
import Network

/// A tiny OpenAI-compatible chat server that runs inside the test process and answers from a script,
/// so a whole turn (lead, delegation, sub-agents, final reply) goes through the app's real request
/// code with no network and no model. It records every request so a test can assert what each
/// speaker was actually sent.
final class ScriptedModelServer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        var system: String
        var toolNames: [String]
        var roles: [String]
        var lastUser: String
        var toolResults: [String]
    }

    /// What to answer: text, or a tool call (name, JSON arguments).
    enum Reply: Sendable {
        case text(String)
        case tool(name: String, arguments: String)
    }

    private let queue = DispatchQueue(label: "scripted-model-server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var recorded: [Request] = []
    private let respond: @Sendable (Request) -> Reply
    private(set) var port: UInt16 = 0

    init(respond: @escaping @Sendable (Request) -> Reply) { self.respond = respond }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            throw NSError(domain: "ScriptedModelServer", code: 1)
        }
        port = p
        self.listener = listener
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let split = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<split.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").compactMap { line -> Int? in
                    let l = line.lowercased()
                    return l.hasPrefix("content-length:") ? Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = buf[split.upperBound...]
                if body.count >= length {
                    self.handle(conn, head: head, body: Data(body.prefix(length)))
                    return
                }
            }
            if done || error != nil { conn.cancel(); return }
            self.read(conn, buffer: buf)
        }
    }

    private func handle(_ conn: NWConnection, head: String, body: Data) {
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        if first.contains("/models") {
            send(conn, status: "200 OK", type: "application/json", body: #"{"data":[{"id":"scripted","object":"model"}]}"#)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            send(conn, status: "400 Bad Request", type: "text/plain", body: "bad request")
            return
        }
        func text(_ m: [String: Any]) -> String {
            if let s = m["content"] as? String { return s }
            if let parts = m["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
            return ""
        }
        let tools = (json["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let request = Request(
            system: messages.filter { ($0["role"] as? String) == "system" }.map(text).joined(separator: "\n"),
            toolNames: tools,
            roles: messages.compactMap { $0["role"] as? String },
            lastUser: messages.last { ($0["role"] as? String) == "user" }.map(text) ?? "",
            toolResults: messages.filter { ($0["role"] as? String) == "tool" }.map(text)
        )
        lock.lock(); recorded.append(request); lock.unlock()

        func chunk(_ delta: [String: Any], finish: String? = nil) -> String {
            var choice: [String: Any] = ["index": 0, "delta": delta]
            if let finish { choice["finish_reason"] = finish }
            let obj: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "choices": [choice]]
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }
        var sse = ""
        switch respond(request) {
        case .text(let t):
            sse += chunk(["role": "assistant", "content": t])
            sse += chunk([:], finish: "stop")
        case .tool(let name, let args):
            sse += chunk(["role": "assistant", "tool_calls": [[
                "index": 0, "id": "call_\(UUID().uuidString.prefix(8))", "type": "function",
                "function": ["name": name, "arguments": args],
            ]]])
            sse += chunk([:], finish: "tool_calls")
        }
        sse += "data: [DONE]\n\n"
        send(conn, status: "200 OK", type: "text/event-stream", body: sse)
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }
}
