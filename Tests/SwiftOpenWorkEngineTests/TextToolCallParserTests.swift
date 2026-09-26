import XCTest
@testable import SwiftOpenWorkEngine

final class TextToolCallParserTests: XCTestCase {
    private let known: (String) -> Bool = { ToolCallRepair.builtInNames.contains(ToolCallRepair.canonicalName($0)) }

    private func args(_ call: TextToolCallParser.Call) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.args.utf8))) as? [String: Any] ?? [:]
    }

    func testNestedParametersSurvive() {
        let text = #"TOOL_CALL = {"tool": "multi_edit", "parameters": {"path": "a.swift", "edits": [{"old_string": "x", "new_string": "y"}]}}"#
        let calls = TextToolCallParser.parse(text, isKnownTool: known)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.tool, "multi_edit")
        XCTAssertEqual((args(calls[0])["edits"] as? [[String: Any]])?.count, 1)
    }

    func testBracesInsideStringsDoNotEndTheObject() {
        let text = #"{"name": "file_write", "arguments": {"path": "a.js", "content": "if (x) { return \"}\"; }"}}"#
        let calls = TextToolCallParser.parse(text, isKnownTool: known)
        XCTAssertEqual(args(calls[0])["content"] as? String, #"if (x) { return "}"; }"#)
    }

    func testPackageJsonInAFenceIsNotACall() {
        let text = "Here is your config:\n```json\n{\"name\": \"my-app\", \"version\": \"1.0.0\", \"scripts\": {\"dev\": \"vite\"}}\n```\n"
        XCTAssertTrue(TextToolCallParser.parse(text, isKnownTool: known).isEmpty)
    }

    func testFencedCallIsParsed() {
        let text = "```tool_call\n{\"tool\": \"file_read\", \"parameters\": {\"path\": \"a\"}}\n```"
        XCTAssertEqual(TextToolCallParser.parse(text, isKnownTool: known).map(\.tool), ["file_read"])
    }

    func testArgumentsGivenAsAJsonString() {
        let text = #"{"name": "file_read", "arguments": "{\"path\": \"a.swift\"}"}"#
        XCTAssertEqual(args(TextToolCallParser.parse(text, isKnownTool: known)[0])["path"] as? String, "a.swift")
    }

    func testOpenAIStyleFunctionObject() {
        let text = #"{"function": {"name": "grep", "arguments": {"pattern": "foo"}}}"#
        let calls = TextToolCallParser.parse(text, isKnownTool: known)
        XCTAssertEqual(calls.first?.tool, "grep")
    }

    func testHermesToolCallTag() {
        let text = #"<tool_call>{"name": "file_list", "arguments": {"path": "."}}</tool_call>"#
        XCTAssertEqual(TextToolCallParser.parse(text, isKnownTool: known).map(\.tool), ["file_list"])
    }

    func testQwenXmlKeepsUnknownNamesSoTheModelGetsAUsefulError() {
        let text = "<tool_call>\n<function=made_up_tool>\n<parameter=path>\na\n</parameter>\n</function>\n</tool_call>"
        let calls = TextToolCallParser.parse(text, isKnownTool: known)
        XCTAssertEqual(calls.first?.tool, "made_up_tool")
        XCTAssertEqual(args(calls[0])["path"] as? String, "a")
    }

    func testInlineCallsToRealToolsOnly() {
        XCTAssertEqual(TextToolCallParser.parse(#"file_read(path="a.swift")"#, isKnownTool: known).map(\.tool), ["file_read"])
        XCTAssertTrue(TextToolCallParser.parse(#"Try print(text="hi") in Python"#, isKnownTool: known).isEmpty)
    }

    func testDuplicatesInOneMessageCollapse() {
        let text = "TOOL_CALL = {\"tool\": \"git_status\"}\n```json\n{\"tool\": \"git_status\"}\n```"
        XCTAssertEqual(TextToolCallParser.parse(text, isKnownTool: known).count, 1)
    }

    func testUnterminatedFenceStillYieldsTheCall() {
        let text = "```json\n{\"tool\": \"git_status\"}"
        XCTAssertEqual(TextToolCallParser.parse(text, isKnownTool: known).count, 1)
    }
}
