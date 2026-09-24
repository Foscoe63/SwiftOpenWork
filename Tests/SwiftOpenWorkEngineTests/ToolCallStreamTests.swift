import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Streamed tool calls must survive being delivered in pieces.
final class ToolCallStreamAssemblerTests: XCTestCase {

    private func piece(index: Int? = 0, id: String? = nil, name: String? = nil, args: Any? = nil) -> [String: Any] {
        var fragment: [String: Any] = [:]
        if let index { fragment["index"] = index }
        if let id { fragment["id"] = id }
        var function: [String: Any] = [:]
        if let name { function["name"] = name }
        if let args { function["arguments"] = args }
        if !function.isEmpty { fragment["function"] = function }
        return fragment
    }

    func testFragmentedArgumentsAreConcatenatedUnderOneId() {
        var assembler = ToolCallStreamAssembler()
        _ = assembler.ingest([piece(id: "call_1", name: "file_read", args: "")])
        _ = assembler.ingest([piece(args: #"{"pa"#)])
        let last = assembler.ingest([piece(args: #"th":"a.swift"}"#)])
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last[0].id, "call_1")
        XCTAssertEqual(last[0].argumentsJson, #"{"path":"a.swift"}"#)
        XCTAssertEqual(assembler.assembled().map(\.argumentsJson), [#"{"path":"a.swift"}"#])
    }

    func testAServerThatNeverSendsAnIdStillGetsOneStableId() {
        var assembler = ToolCallStreamAssembler()
        let first = assembler.ingest([piece(name: "grep", args: #"{"pattern":"#)])
        let second = assembler.ingest([piece(args: #""x"}"#)])
        XCTAssertEqual(first[0].id, second[0].id, "a new id per piece made every fragment a separate call")
        XCTAssertFalse(first[0].id.isEmpty)
    }

    func testParallelCallsComeBackInTheOrderTheyWereMade() {
        var assembler = ToolCallStreamAssembler()
        _ = assembler.ingest([piece(index: 2, id: "c", name: "third", args: "{}")])
        _ = assembler.ingest([piece(index: 0, id: "a", name: "first", args: "{}")])
        _ = assembler.ingest([piece(index: 1, id: "b", name: "second", args: "{}")])
        XCTAssertEqual(assembler.assembled().map(\.toolName), ["first", "second", "third"])
    }

    func testArgumentsSentAsAnObjectAreKept() throws {
        var assembler = ToolCallStreamAssembler()
        let out = assembler.ingest([piece(id: "x", name: "file_read", args: ["path": "a.swift"])])
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(with: Data(out[0].argumentsJson.utf8)) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "a.swift")
    }

    func testAMissingIndexFallsBackToPosition() {
        var assembler = ToolCallStreamAssembler()
        _ = assembler.ingest([piece(index: nil, id: "a", name: "one", args: "{}"), piece(index: nil, id: "b", name: "two", args: "{}")])
        XCTAssertEqual(assembler.assembled().map(\.toolName), ["one", "two"])
    }

    func testAPieceBeforeTheNameIsNotYetACall() {
        var assembler = ToolCallStreamAssembler()
        XCTAssertTrue(assembler.ingest([piece(id: "a", args: "{")]).isEmpty)
        XCTAssertTrue(assembler.assembled().isEmpty)
        XCTAssertEqual(assembler.ingest([piece(name: "grep", args: "}")]).first?.argumentsJson, "{}")
    }

    func testNoArgumentsBecomeAnEmptyObject() {
        var assembler = ToolCallStreamAssembler()
        _ = assembler.ingest([piece(id: "a", name: "git_status")])
        XCTAssertEqual(assembler.assembled().first?.argumentsJson, "{}")
    }
}

/// The agent loop keys tool calls by id, and the latest snapshot of a call is the complete one.
final class ToolCallCollectorTests: XCTestCase {
    func testALaterSnapshotReplacesAnEarlierOneWithTheSameId() {
        let collector = AgentToolCallCollector()
        collector.add(ToolCallInfo(id: "c1", toolName: "file_read", argumentsJson: ""))
        collector.add(ToolCallInfo(id: "c1", toolName: "file_read", argumentsJson: #"{"path":"a"}"#))
        let held = collector.snapshot()
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].argumentsJson, #"{"path":"a"}"#, "the first, empty snapshot used to win")
    }

    func testDistinctCallsKeepTheirOrder() {
        let collector = AgentToolCallCollector()
        collector.add(ToolCallInfo(id: "a", toolName: "one", argumentsJson: "{}"))
        collector.add(ToolCallInfo(id: "b", toolName: "two", argumentsJson: "{}"))
        collector.add(ToolCallInfo(id: "a", toolName: "one", argumentsJson: #"{"x":1}"#))
        XCTAssertEqual(collector.snapshot().map(\.id), ["a", "b"])
        XCTAssertEqual(collector.snapshot()[0].argumentsJson, #"{"x":1}"#)
    }
}
