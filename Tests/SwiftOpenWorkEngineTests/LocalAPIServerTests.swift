import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

private struct StubBackend: LocalAPIBackend {
    func models() async -> [(id: String, owner: String)] { [("local-model", "Test")] }
    func generate(_ request: LocalAPIProtocol.Request, onChunk: @Sendable @escaping (LLMStreamChunk) -> Void) async throws {
        if request.model == "boom" { throw LocalAPIProtocol.Failure(status: 404, message: "no such model") }
        onChunk(LLMStreamChunk(deltaText: "Hel"))
        onChunk(LLMStreamChunk(deltaText: "lo"))
        if !request.tools.isEmpty {
            onChunk(LLMStreamChunk(toolCalls: [ToolCallInfo(id: "call_1", toolName: request.tools[0].name, argumentsJson: #"{"path":"a.txt"}"#, status: .completed)]))
        }
        onChunk(LLMStreamChunk(isFinished: true, finishReason: "stop", promptTokens: 7, completionTokens: 2))
    }
}

final class LocalAPIProtocolTests: XCTestCase {
    func testOpenAIRequestMapsSystemToolsAndToolResults() throws {
        let json = """
        {"model":"m","stream":true,"max_tokens":99,"temperature":0.2,
         "messages":[{"role":"system","content":"be brief"},{"role":"user","content":[{"type":"text","text":"read a.txt"},{"type":"image_url","image_url":{"url":"x"}}]},
           {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{\\"path\\":\\"a.txt\\"}"}}]},
           {"role":"tool","tool_call_id":"c1","content":"file text"}],
         "tools":[{"type":"function","function":{"name":"read","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}}]}
        """
        let request = try LocalAPIProtocol.parse(Data(json.utf8), flavor: .openAI)
        XCTAssertEqual(request.system, "be brief")
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.maxTokens, 99)
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertTrue(request.messages[0].content.contains("read a.txt"))
        XCTAssertTrue(request.messages[0].content.contains("image omitted"))
        XCTAssertEqual(request.messages[1].toolCalls.first?.toolName, "read")
        XCTAssertEqual(request.messages[2].id, "c1", "a tool result is paired to its call by id")
        XCTAssertEqual(request.tools.first?.name, "read")
        XCTAssertTrue(request.tools[0].parametersJsonSchema.contains("\"path\""))
    }

    func testAnthropicRequestMapsBlocks() throws {
        let json = """
        {"model":"claude-x","system":[{"type":"text","text":"sys A"},{"type":"text","text":"sys B"}],"max_tokens":50,
         "messages":[{"role":"user","content":"hi"},
           {"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"tu1","name":"bash","input":{"command":"ls"}}]},
           {"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"a b"}]},{"type":"text","text":"thanks"}]}],
         "tools":[{"name":"bash","description":"run","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}]}
        """
        let request = try LocalAPIProtocol.parse(Data(json.utf8), flavor: .anthropic)
        XCTAssertEqual(request.system, "sys A\nsys B")
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .tool, .user])
        XCTAssertEqual(request.messages[1].toolCalls.first?.argumentsJson, #"{"command":"ls"}"#)
        XCTAssertEqual(request.messages[2].id, "tu1")
        XCTAssertEqual(request.messages[2].content, "a b")
        XCTAssertEqual(request.tools.first?.name, "bash")
    }

    func testBadBodiesAreClientErrors() {
        XCTAssertThrowsError(try LocalAPIProtocol.parse(Data("nope".utf8), flavor: .openAI)) { XCTAssertEqual(($0 as? LocalAPIProtocol.Failure)?.status, 400) }
        XCTAssertThrowsError(try LocalAPIProtocol.parse(Data(#"{"messages":[]}"#.utf8), flavor: .openAI))
    }

    func testResponsesCarryToolCallsAndFinishReasons() throws {
        var completion = LocalAPIProtocol.Completion(text: "", toolCalls: [ToolCallInfo(id: "c9", toolName: "read", argumentsJson: "{}", status: .completed)], finishReason: "stop", promptTokens: 3, completionTokens: 4)
        let openAI = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIProtocol.openAIResponse(id: "i", model: "m", completion)) as? [String: Any])
        let choice = try XCTUnwrap((openAI["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        XCTAssertEqual(((choice["message"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "c9")
        let anthropic = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIProtocol.anthropicResponse(id: "i", model: "m", completion)) as? [String: Any])
        XCTAssertEqual(anthropic["stop_reason"] as? String, "tool_use")
        completion.toolCalls = []; completion.finishReason = "length"
        XCTAssertEqual(completion.openAIFinish, "length")
        XCTAssertEqual(completion.anthropicStop, "max_tokens")
    }
}

final class LocalAPIServerTests: XCTestCase {
    private let token = "swo-test-token"
    private var port: UInt16 = 0
    private let server = LocalAPIServer()

    override func setUpWithError() throws {
        port = UInt16.random(in: 40_000...60_000)
        try server.start(port: port, token: token, backend: StubBackend())
    }
    override func tearDown() { server.stop() }

    private func call(_ path: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:], auth: Bool = true) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    func testHealthNeedsNoTokenButEverythingElseDoes() async throws {
        let health = try await call("/health", auth: false)
        XCTAssertEqual(health.0, 200)
        let models = try await call("/v1/models", auth: false)
        XCTAssertEqual(models.0, 401)
        let wrong = try await call("/v1/models", headers: ["Authorization": "Bearer nope"])
        XCTAssertEqual(wrong.0, 401)
        let ok = try await call("/v1/models")
        XCTAssertEqual(ok.0, 200)
        XCTAssertTrue(ok.1.contains("local-model"))
        let anthropicHeader = try await call("/v1/models", headers: ["Authorization": "", "x-api-key": token])
        XCTAssertEqual(anthropicHeader.0, 200, "x-api-key works for Anthropic clients")
    }

    func testBrowserRequestsAreRefused() async throws {
        let result = try await call("/v1/models", headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(result.0, 403)
    }

    func testHostMustBeLoopback() {
        func head(_ host: String) -> LocalAPIServer.Head { .init(method: "GET", path: "/v1/models", headers: ["host": host, "authorization": "Bearer t"], bodyOffset: 0) }
        XCTAssertNil(LocalAPIServer.rejection(for: head("localhost:11500"), token: "t"))
        XCTAssertNil(LocalAPIServer.rejection(for: head("127.0.0.1:11500"), token: "t"))
        XCTAssertNil(LocalAPIServer.rejection(for: head("[::1]:11500"), token: "t"))
        XCTAssertEqual(LocalAPIServer.rejection(for: head("attacker.example:11500"), token: "t")?.status, 403, "DNS rebinding")
        XCTAssertEqual(LocalAPIServer.rejection(for: head("192.168.1.5"), token: "t")?.status, 403)
    }

    func testTokenComparison() {
        XCTAssertTrue(LocalAPIServer.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(LocalAPIServer.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(LocalAPIServer.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(LocalAPIServer.constantTimeEqual("", "x"))
    }

    func testChatCompletionNonStreaming() async throws {
        let (status, body) = try await call("/v1/chat/completions", method: "POST", body: #"{"model":"local-model","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(status, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let message = try XCTUnwrap(((object["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Hello")
        XCTAssertEqual((object["usage"] as? [String: Any])?["prompt_tokens"] as? Int, 7)
    }

    func testChatCompletionStreamingEndsWithDone() async throws {
        let (status, body) = try await call("/v1/chat/completions", method: "POST", body: #"{"model":"local-model","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"content\":\"Hel\""))
        XCTAssertTrue(body.contains("\"content\":\"lo\""))
        XCTAssertTrue(body.hasSuffix("data: [DONE]\n\n"))
    }

    func testToolCallsComeBack() async throws {
        let request = #"{"model":"local-model","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"read","parameters":{"type":"object"}}}]}"#
        let (_, body) = try await call("/v1/chat/completions", method: "POST", body: request)
        XCTAssertTrue(body.contains("\"finish_reason\":\"tool_calls\""))
        XCTAssertTrue(body.contains("call_1"))
    }

    func testAnthropicMessagesStreamAndNonStream() async throws {
        let plain = try await call("/v1/messages", method: "POST", body: #"{"model":"local-model","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}"#, headers: ["anthropic-version": "2023-06-01"])
        XCTAssertEqual(plain.0, 200)
        XCTAssertTrue(plain.1.contains("\"stop_reason\":\"end_turn\""))
        let streamed = try await call("/v1/messages", method: "POST", body: #"{"model":"local-model","max_tokens":10,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        for event in ["message_start", "content_block_start", "text_delta", "message_delta", "message_stop"] {
            XCTAssertTrue(streamed.1.contains(event), event)
        }
    }

    func testBackendFailuresBecomeHTTPErrors() async throws {
        let result = try await call("/v1/chat/completions", method: "POST", body: #"{"model":"boom","messages":[{"role":"user","content":"x"}]}"#)
        XCTAssertEqual(result.0, 404)
        XCTAssertTrue(result.1.contains("no such model"))
        let unknown = try await call("/v1/nope")
        XCTAssertEqual(unknown.0, 404)
    }
}
