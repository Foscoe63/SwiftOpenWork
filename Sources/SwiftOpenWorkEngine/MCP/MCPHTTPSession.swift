import Foundation
import SwiftOpenWorkCore

public enum MCPHTTPError: LocalizedError {
    case badURL(String)
    case auth(hadCredentials: Bool)
    case http(Int, String)
    case rpc(String)
    case malformed(String)
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .badURL(let url):
            return "Missing or invalid URL for HTTP MCP server: \(url)"
        case .auth(let hadCredentials):
            return hadCredentials
                ? "That server rejected the token — check it is current and has the right scope."
                : "That server needs you to sign in. Paste an access token in headers/env; SwiftOpenWork cannot yet do a full OAuth sign-in for MCP servers."
        case .http(let code, let body):
            if code == 404 || code == 405 {
                return "HTTP \(code) from the server. It may only speak the older SSE transport, which is not supported; use a Streamable HTTP URL."
                    + (body.isEmpty ? "" : " (\(body))")
            }
            return "HTTP \(code) from the server" + (body.isEmpty ? "." : ": \(body)")
        case .rpc(let message):
            return message
        case .malformed(let what):
            return "Unexpected response from the server: \(what)"
        case .sessionExpired:
            return "The server's session expired."
        }
    }
}

/// One MCP server reached over Streamable HTTP.
///
/// The earlier HTTP path sent a bare `tools/list` with no `initialize` handshake and no session
/// id, could not read a reply sent as `text/event-stream`, sent the server's `env` values as HTTP
/// headers, and ignored `isError`. Servers that follow the specification refused all of that.
/// This does what the specification asks: initialize, remember `Mcp-Session-Id`, accept a JSON or
/// SSE reply, page through `tools/list`, and reconnect once if the session has expired.
public actor MCPHTTPSession {
    public let config: MCPServerConfig

    private var sessionId: String?
    private var protocolVersion = "2025-03-26"
    private var initialized = false
    private var nextId = 1
    private let urlSession: URLSession

    public init(config: MCPServerConfig, urlSession: URLSession? = nil) {
        self.config = config
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() async throws -> [MCPToolDefinition] {
        try await initialize()
        return try await listTools()
    }

    public func stop() async {
        guard let sessionId, let url = URL(string: config.url) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 3
        applyHeaders(to: &request)
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await urlSession.data(for: request)
        self.sessionId = nil
        initialized = false
    }

    private func initialize() async throws {
        sessionId = nil
        initialized = false
        let params: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "SwiftOpenWork", "version": "1.0.0"],
        ]
        let id = takeId()
        let (data, http) = try await post(
            ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": params], timeout: 20
        )
        let message = try Self.extractResponse(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = message["error"] as? [String: Any] {
            throw MCPHTTPError.rpc("MCP initialize failed: \(error["message"] as? String ?? "\(error)")")
        }
        if let result = message["result"] as? [String: Any], let version = result["protocolVersion"] as? String {
            protocolVersion = version
        }
        sessionId = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        initialized = true
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"], timeout: 10)
    }

    // MARK: - Requests

    public func listTools() async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request("tools/list", params: params, timeout: 20)
            for entry in (result["tools"] as? [[String: Any]]) ?? [] {
                tools.append(MCPToolDefinition.fromToolsListEntry(entry))
            }
            cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while cursor != nil && pages < 20
        return tools
    }

    /// The text the model should see, or an "Error: …" string when the tool reported `isError`.
    public func callTool(name: String, arguments: sending [String: Any]) async throws -> String {
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: 120)
        let text = Self.render(result)
        if (result["isError"] as? Bool) == true {
            return "Error: MCP tool '\(name)' on '\(config.name)' reported an error: \(text.isEmpty ? "(no message)" : text)"
        }
        return text.isEmpty ? "(no output)" : text
    }

    /// One request, with a single reconnect if the server has forgotten the session.
    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        do {
            return try await requestOnce(method, params: params, timeout: timeout)
        } catch MCPHTTPError.sessionExpired {
            try await initialize()
            return try await requestOnce(method, params: params, timeout: timeout)
        }
    }

    private func requestOnce(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if !initialized { try await initialize() }
        let id = takeId()
        let (data, http) = try await post(
            ["jsonrpc": "2.0", "id": id, "method": method, "params": params], timeout: timeout
        )
        let message = try Self.extractResponse(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = message["error"] as? [String: Any] {
            throw MCPHTTPError.rpc("MCP Error from '\(config.name)': \(error["message"] as? String ?? "\(error)")")
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func takeId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    // MARK: - Transport

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in config.headers { request.setValue(value, forHTTPHeaderField: key) }
        // Optional bearer token via env["MCP_TOKEN"] / env["token"] / env["TOKEN"]. The env is
        // *only* read for this: it is a process environment for stdio servers, not a header set.
        if request.value(forHTTPHeaderField: "Authorization") == nil,
           let token = config.env["MCP_TOKEN"] ?? config.env["token"] ?? config.env["TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if initialized { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
    }

    private var hadCredentials: Bool {
        config.headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
            || config.env["MCP_TOKEN"] != nil || config.env["token"] != nil || config.env["TOKEN"] != nil
    }

    private func post(
        _ body: [String: Any], timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: config.url), !config.url.isEmpty else {
            throw MCPHTTPError.badURL(config.url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        applyHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPHTTPError.malformed("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401, 403:
            throw MCPHTTPError.auth(hadCredentials: hadCredentials)
        case 404 where sessionId != nil:
            // A session id was issued and is now unknown: the server restarted or expired it.
            throw MCPHTTPError.sessionExpired
        default:
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MCPHTTPError.http(http.statusCode, snippet)
        }
    }

    // MARK: - Parsing (pure, so it can be tested without a server)

    /// The JSON-RPC message answering `id`, from either a JSON body or an SSE stream of them.
    static func extractResponse(data: Data, contentType: String?, id: Int) throws -> [String: Any] {
        func matches(_ object: [String: Any]) -> Bool {
            guard object["result"] != nil || object["error"] != nil else { return false }
            if let value = object["id"] as? Int { return value == id }
            if let value = object["id"] as? String { return Int(value) == id }
            return false
        }
        func find(in json: Any) -> [String: Any]? {
            if let object = json as? [String: Any], matches(object) { return object }
            if let array = json as? [[String: Any]] { return array.first(where: matches) }
            return nil
        }

        let isStream = contentType?.lowercased().contains("text/event-stream") == true
        if !isStream {
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                // Some servers label an SSE body `application/json`; try that before giving up.
                if let found = scanEvents(String(decoding: data, as: UTF8.self), where: find) { return found }
                throw MCPHTTPError.malformed("the body was not JSON")
            }
            if let found = find(in: json) { return found }
            throw MCPHTTPError.malformed("no reply to request \(id)")
        }
        if let found = scanEvents(String(decoding: data, as: UTF8.self), where: find) { return found }
        throw MCPHTTPError.malformed("the event stream had no reply to request \(id)")
    }

    private static func scanEvents(_ text: String, where find: (Any) -> [String: Any]?) -> [String: Any]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for event in normalized.components(separatedBy: "\n\n") {
            var dataLines: [String] = []
            for line in event.components(separatedBy: "\n") where line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
            guard !dataLines.isEmpty,
                  let payload = dataLines.joined(separator: "\n").data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payload),
                  let found = find(json) else { continue }
            return found
        }
        return nil
    }

    /// A `tools/call` result as text.
    static func render(_ result: [String: Any]) -> String {
        var parts: [String] = []
        for item in (result["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "image" where item["data"] is String:
                parts.append(MCPMedia.describeImage(base64: item["data"] as? String ?? "", mimeType: item["mimeType"] as? String ?? "image/png"))
            case "image", "audio":
                let kind = item["type"] as? String ?? "media"
                let mime = item["mimeType"] as? String
                parts.append(mime.map { "[\(kind) \($0)]" } ?? "[\(kind)]")
            case "resource":
                let resource = item["resource"] as? [String: Any]
                if let text = resource?["text"] as? String { parts.append(text) }
                else if let uri = resource?["uri"] as? String { parts.append("[resource \(uri)]") }
            case "resource_link":
                parts.append("[resourceLink \(item["name"] as? String ?? "") \(item["uri"] as? String ?? "")]")
            default:
                break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return parts.joined(separator: "\n")
    }
}
