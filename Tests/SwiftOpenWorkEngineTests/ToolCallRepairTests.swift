import XCTest
@testable import SwiftOpenWorkEngine

final class ToolCallRepairTests: XCTestCase {

    // MARK: Names

    func testLooseSpellingsResolveToBuiltIns() {
        let expectations: [String: String] = [
            "read": "file_read", "cat": "file_read", "Read": "file_read", "functions.read_file": "file_read",
            "bash": "terminal_command", "shell": "terminal_command", "run_terminal_cmd": "terminal_command",
            "edit": "edit_file", "str_replace": "edit_file", "multiedit": "multi_edit",
            "write": "file_write", "list_dir": "file_list", "search": "grep", "find": "glob",
            "build": "build_project", "fetch": "fetch_url",
        ]
        for (raw, canonical) in expectations {
            XCTAssertEqual(ToolCallRepair.canonicalName(raw), canonical, raw)
            XCTAssertEqual(ToolCallRepair.resolve(raw, mcpAdvertised: []), canonical, raw)
        }
    }

    func testAnMcpServersOwnToolBeatsALooseAlias() {
        XCTAssertEqual(ToolCallRepair.resolve("read", mcpAdvertised: ["read"]), "read")
        XCTAssertEqual(ToolCallRepair.resolve("search", mcpAdvertised: ["search"]), "search")
        // Spellings the dispatcher already claimed keep doing so.
        XCTAssertEqual(ToolCallRepair.resolve("read_file", mcpAdvertised: ["read_file"]), "file_read")
    }

    func testMcpToolNamesArePassedThroughUntouched() {
        XCTAssertEqual(ToolCallRepair.resolve("mcp__Server-1__List_Things", mcpAdvertised: []), "mcp__Server-1__List_Things")
        XCTAssertEqual(ToolCallRepair.resolve("Some_Custom_Tool", mcpAdvertised: []), "Some_Custom_Tool")
    }

    func testEveryAliasTargetIsABuiltIn() {
        for raw in ["read", "bash", "edit", "write", "search", "find", "rm", "ls", "cp", "mv", "fetch", "todo", "calc"] {
            XCTAssertTrue(ToolCallRepair.builtInNames.contains(ToolCallRepair.canonicalName(raw)), raw)
        }
    }

    func testUnknownToolNamesTheNearestRealOnes() {
        let message = ToolCallRepair.unknownToolMessage("file_reed", mcpServerSummary: nil)
        XCTAssertTrue(message.contains("`file_read`"), message)
        XCTAssertFalse(message.contains("MCP servers are enabled"), "an unknown built-in is not an MCP problem")
        XCTAssertTrue(ToolCallRepair.unknownToolMessage("zzz", mcpServerSummary: "acme (`a1`)").contains("acme"))
    }

    // MARK: Arguments

    func testAlternativeKeysFillOurs() {
        let edit = ToolCallRepair.normalizeArguments(tool: "edit_file", [
            "file_path": "a.swift", "old_str": "x", "new_str": "y", "replaceAll": "true",
        ])
        XCTAssertEqual(edit["path"] as? String, "a.swift")
        XCTAssertEqual(edit["old_string"] as? String, "x")
        XCTAssertEqual(edit["new_string"] as? String, "y")
        XCTAssertEqual(edit["replace_all"] as? Bool, true)

        let shell = ToolCallRepair.normalizeArguments(tool: "terminal_command", ["cmd": "ls"])
        XCTAssertEqual(shell["command"] as? String, "ls")

        let move = ToolCallRepair.normalizeArguments(tool: "file_move", ["from": "a", "to": "b"])
        XCTAssertEqual(move["source"] as? String, "a")
        XCTAssertEqual(move["destination"] as? String, "b")
    }

    func testACorrectCallIsNotTouched() {
        let args: [String: Any] = ["path": "a.swift", "old_string": "x", "new_string": "y", "replace_all": false]
        let out = ToolCallRepair.normalizeArguments(tool: "edit_file", args)
        XCTAssertEqual(out["path"] as? String, "a.swift")
        XCTAssertEqual(out["replace_all"] as? Bool, false)
        XCTAssertEqual(out.count, args.count)
    }

    func testEmptyPrimaryKeyIsFilledFromAlias() {
        let out = ToolCallRepair.normalizeArguments(tool: "file_read", ["path": "", "file_path": "b.swift"])
        XCTAssertEqual(out["path"] as? String, "b.swift")
    }

    func testStartAndEndLineBecomeALimit() {
        let out = ToolCallRepair.normalizeArguments(tool: "file_read", ["path": "a", "start_line": "10", "end_line": 19])
        XCTAssertEqual(ToolExecutionEngine.intArgument(out["limit"]), 10)
    }

    func testPathHygiene() {
        XCTAssertEqual(ToolCallRepair.cleanPath("  \"/a/b.swift\" "), "/a/b.swift")
        XCTAssertEqual(ToolCallRepair.cleanPath("file:///a/b%20c.swift"), "/a/b c.swift")
        XCTAssertEqual(ToolCallRepair.cleanPath("~/x"), NSHomeDirectory() + "/x")
    }

    func testNonBuiltInArgumentsAreLeftAlone() {
        let args: [String: Any] = ["path": " \"quoted\" ", "force": "true"]
        let out = ToolCallRepair.normalizeArguments(tool: "mcp__srv__thing", args)
        XCTAssertEqual(out["path"] as? String, " \"quoted\" ")
        XCTAssertEqual(out["force"] as? String, "true")
    }

    // MARK: Fixtures from real sessions

    func testRealExportedCallsRepair() {
        // `read` with numeric strings, from a Qwen3-Coder session export.
        XCTAssertEqual(ToolCallRepair.resolve("read", mcpAdvertised: []), "file_read")
        let args = ToolCallRepair.normalizeArguments(tool: "file_read", [
            "limit": "20.0", "offset": "165.0", "path": "/x/ANSIParser.swift",
        ])
        XCTAssertEqual(ToolExecutionEngine.intArgument(args["limit"]), 20)
        XCTAssertEqual(ToolExecutionEngine.intArgument(args["offset"]), 165)
    }
}

final class LineNumberGutterTests: XCTestCase {
    func testPastedReadOutputIsStripped() {
        let pasted = "1806\t  // Filter\n1807\t  if x {\n1808\t  }"
        XCTAssertEqual(ToolCallRepair.stripLineNumberGutter(pasted), "  // Filter\n  if x {\n  }")
        XCTAssertEqual(ToolCallRepair.stripLineNumberGutter("  95\tlet a = 1"), "let a = 1")
    }

    func testOrdinaryCodeIsUntouched() {
        XCTAssertEqual(ToolCallRepair.stripLineNumberGutter("let a = 1\nlet b = 2"), "let a = 1\nlet b = 2")
        // One numbered line among unnumbered ones is code, not a gutter.
        XCTAssertEqual(ToolCallRepair.stripLineNumberGutter("12\tfoo\nbar"), "12\tfoo\nbar")
    }

    func testEditFileArgumentsAreCleaned() {
        let out = ToolCallRepair.normalizeArguments(tool: "edit_file", [
            "path": "a", "old_string": "10\tlet a = 1", "new_string": "10\tlet a = 2",
        ])
        XCTAssertEqual(out["old_string"] as? String, "let a = 1")
        XCTAssertEqual(out["new_string"] as? String, "let a = 2")
    }

    func testMultiEditEditsAreCleaned() throws {
        let edits = try XCTUnwrap(MultiEdit.parseEdits(from: ["edits": [["old_string": "3\tfoo", "new_string": "3\tbar"]]]))
        XCTAssertEqual(edits.first?.oldString, "foo")
    }
}
