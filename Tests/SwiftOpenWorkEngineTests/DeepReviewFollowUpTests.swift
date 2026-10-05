import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// The second half of the deep review: isolation holes, prompt caching, deferred MCP schemas,
/// MCP images and the stdio buffer, plan mode, and the smaller fixes.
@MainActor
final class DeepReviewFollowUpTests: XCTestCase {

    private func tool(_ name: String, _ description: String = "") -> Tool {
        Tool(id: name, name: name, displayName: name, description: description, category: .files,
             parametersJsonSchema: #"{"type":"object","properties":{}}"#)
    }

    // MARK: - Sub-agent isolation (#12)

    func testAShellCommandThatWritesOutsideTheWorktreeIsRefusedWhateverTheApprovalLevel() {
        let worktree = NSTemporaryDirectory() + "wt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.terminalSafetyLevel = .allowEverything
        func reason(_ command: String, cwd: String? = nil) -> String? {
            var args: [String: Any] = ["command": command]
            if let cwd { args["cwd"] = cwd }
            let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
            return SubAgentToolPolicy.approvalReason(
                toolName: "terminal_command", argumentsJson: json, worktreePath: worktree,
                settings: settings, sessionId: "s"
            )
        }
        XCTAssertNotNil(reason("echo hi > /Users/someone/notes.txt"))
        XCTAssertNotNil(reason("cd /Users/someone/project && sed -i '' s/a/b/ f.swift"))
        XCTAssertNotNil(reason("git -C /Users/someone/project checkout ."))
        XCTAssertNotNil(reason("ls", cwd: "/Users/someone/project"))
        XCTAssertNil(reason("swift build > /dev/null 2>&1"), "the standard devices write nothing")
        XCTAssertNil(reason("echo hi > out.txt"), "a relative path lands in the worktree")
        XCTAssertNil(reason("echo hi > \(worktree)/out.txt"))
    }

    func testStatusEntriesNameARenamedFileByItsNewNameAndKeepQuotedPathsWhole() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: [String]) throws {
            _ = try Process.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", dir.path] + args, terminationHandler: nil)
            // Run to completion before the next call.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try git(["init", "-q"])
        try "x".write(to: dir.appendingPathComponent("old name.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-q", "-m", "one"])
        try git(["mv", "old name.txt", "new name.txt"])
        let changed = await SubAgentExecutor.changedFiles(in: dir.path)
        XCTAssertEqual(changed, ["new name.txt"])
        // Entries present before the run are not the sub-agent's.
        let before = Set(await SubAgentExecutor.statusEntries(in: dir.path))
        let after = await SubAgentExecutor.changedFiles(in: dir.path, excluding: before)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Prompt caching (#13)

    func testThePromptSplitsAtTheCacheBoundaryAndFlattensForOtherProviders() {
        let joined = PromptCache.join(stable: "stable", volatile: "Git: on main")
        let parts = PromptCache.split(joined)
        XCTAssertEqual(parts.stable, "stable")
        XCTAssertEqual(parts.volatile, "Git: on main")
        XCTAssertFalse(PromptCache.flattened(joined).contains(PromptCache.boundary))
        XCTAssertEqual(PromptCache.join(stable: "stable", volatile: "  \n"), "stable")
        XCTAssertEqual(PromptCache.split("plain").volatile, "")
    }

    func testTheRollingBreakpointLandsOnTheLastBlockAndNeverOnThinking() {
        let mark: [String: Any] = ["type": "ephemeral"]
        var plain: [[String: Any]] = [["role": "user", "content": "hello"]]
        AnthropicService.markRollingBreakpoint(in: &plain, mark: mark)
        let blocks = plain[0]["content"] as? [[String: Any]]
        XCTAssertNotNil(blocks?.last?["cache_control"])

        var withThinking: [[String: Any]] = [["role": "assistant", "content": [
            ["type": "text", "text": "a"], ["type": "thinking", "thinking": "t"],
        ] as [[String: Any]]]]
        AnthropicService.markRollingBreakpoint(in: &withThinking, mark: mark)
        let out = withThinking[0]["content"] as? [[String: Any]]
        XCTAssertNotNil(out?[0]["cache_control"])
        XCTAssertNil(out?[1]["cache_control"])
    }

    func testTheGitLineIsKeptOutOfTheStablePrompt() {
        let snapshot = WorkspaceContext.Snapshot(path: "/p", gitBranch: "main", gitChanges: ["a.swift"], gitChangeCount: 1)
        XCTAssertFalse(WorkspaceContext.promptBlock(snapshot, includeGit: false).contains("Git:"))
        XCTAssertTrue(WorkspaceContext.promptBlock(snapshot).contains("Git:"))
        XCTAssertTrue(WorkspaceContext.gitLine(snapshot).contains("1 uncommitted"))
    }

    // MARK: - Deferred MCP schemas (#14)

    func testManyMCPToolsAreDeferredAndFoundByKeyword() {
        XCTAssertFalse(MCPToolSearch.shouldDefer(toolCount: 12))
        XCTAssertTrue(MCPToolSearch.shouldDefer(toolCount: 13))
        let tools = [
            tool("mcp__gh__create_issue", "Create an issue in a repository"),
            tool("mcp__gh__list_issues", "List issues"),
            tool("mcp__fs__read_file", "Read a file"),
        ]
        XCTAssertEqual(MCPToolSearch.match(query: "mcp__fs__read_file", in: tools).map(\.name), ["mcp__fs__read_file"])
        XCTAssertEqual(Set(MCPToolSearch.match(query: "issue", in: tools).map(\.name)),
                       ["mcp__gh__create_issue", "mcp__gh__list_issues"])
        XCTAssertEqual(MCPToolSearch.match(query: "create issue", in: tools).first?.name, "mcp__gh__create_issue")
        XCTAssertTrue(MCPToolSearch.match(query: "nonsense", in: tools).isEmpty)
        XCTAssertTrue(MCPToolSearch.describe(tools).contains("Parameters:"))
    }

    func testTheDeferredListingCarriesNamesAndDescriptionsButNoSchemas() {
        let listing = MCPToolSearch.listing(tools: [tool("mcp__gh__create_issue", "Create an issue. Needs a title.")]) { _ in "GitHub" }
        XCTAssertTrue(listing.contains("create_issue"))
        XCTAssertTrue(listing.contains("Create an issue"))
        XCTAssertFalse(listing.contains("Needs a title"))
        XCTAssertFalse(listing.contains("properties"))
    }

    func testMcpDescribeIsABuiltInAndReadOnlyInPlanMode() {
        XCTAssertNotNil(ToolSchemaCatalog.parityDefaults.first { $0.name == "mcp_describe" })
        XCTAssertNotNil(ToolSchemaCatalog.parityDefaults.first { $0.name == "mcp_resources" })
        XCTAssertFalse(ToolCallRepair.isBlockedInPlanMode("mcp_describe"))
    }

    // MARK: - MCP media and the stdio buffer (#15, #16)

    func testAnMCPImageIsSavedAndFoundAgainFromTheResultText() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()
        let text = "before\n" + MCPMedia.describeImage(base64: png, mimeType: "image/png") + "\nafter"
        let paths = MCPMedia.paths(in: text)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths[0]))
        XCTAssertEqual(MCPMedia.describeImage(base64: "!!!", mimeType: "image/png"), "[image image/png]")
        try? FileManager.default.removeItem(atPath: paths[0])
    }

    func testTakingOneReplyLeavesTheRepliesToOtherCallsInTheBuffer() {
        let buffer = MCPStdioBuffer()
        buffer.append(Data(#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"three"}]}}"#.utf8) + Data("\n".utf8))
        buffer.append(Data(#"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"four"}]}}"#.utf8) + Data("\n".utf8))
        // Reply 4 is asked for first, though 3 arrived before it.
        XCTAssertEqual(buffer.extractJSONRPCResponse(id: 4), "four")
        XCTAssertEqual(buffer.extractJSONRPCResponse(id: 3), "three")
    }

    func testTheHandshakeCanReadAResultAsJSON() {
        let buffer = MCPStdioBuffer()
        buffer.append(Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a"}]}}"#.utf8) + Data("\n".utf8))
        let raw = buffer.extractJSONRPCResponse(id: 2, raw: true) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        XCTAssertEqual((json?["tools"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Plan mode (#17)

    func testPlanModeBlocksDelegationAndTypingIntoARunningProgram() {
        XCTAssertTrue(ToolCallRepair.isBlockedInPlanMode("agent_spawn"))
        XCTAssertTrue(ToolCallRepair.isBlockedInPlanMode("send_input"))
    }

    func testPlanModeRefusesAnMCPToolItCannotPositivelyCallARead() async {
        var settings = AppSettings.default
        settings.mcpServers = [MCPServerConfig(id: "srv", name: "Srv", command: "x")]
        let refused = await AgentRunner.planModeRefusesMCP(
            toolName: "mcp__srv__delete_everything", argumentsJson: "{}", settings: settings
        )
        XCTAssertTrue(refused)
        let notMCP = await AgentRunner.planModeRefusesMCP(toolName: "file_read", argumentsJson: "{}", settings: settings)
        XCTAssertFalse(notMCP)
    }

    // MARK: - Smaller fixes

    func testHTMLBecomesReadableTextWithLinksKept() {
        let html = """
        <html><head><title>t</title><style>p{color:red}</style><script>var a=1;</script></head>
        <body><h1>Title</h1><p>Hello &amp; welcome to <a href="https://x.dev/a">the site</a>.</p>
        <ul><li>one</li><li>two</li></ul></body></html>
        """
        let text = HTMLText.convert(html)
        XCTAssertTrue(text.contains("# Title"))
        XCTAssertTrue(text.contains("Hello & welcome to the site (https://x.dev/a)."))
        XCTAssertTrue(text.contains("- one"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertFalse(text.contains("var a"))
        XCTAssertTrue(HTMLText.looksLikeHTML(contentType: "text/html; charset=utf-8", body: ""))
        XCTAssertTrue(HTMLText.looksLikeHTML(contentType: nil, body: "<!DOCTYPE html><html>"))
        XCTAssertFalse(HTMLText.looksLikeHTML(contentType: "application/json", body: "{}"))
    }

    func testReadOnlyGitIsRunWithoutTheRepositorysConfiguredPrograms() {
        XCTAssertEqual(
            SafeShellCommand.hardenedForSafeLevel("git diff HEAD~1 | head"),
            "git diff --no-ext-diff --no-textconv HEAD~1 | head"
        )
        XCTAssertEqual(SafeShellCommand.hardenedForSafeLevel("git status"), "git status")
        XCTAssertEqual(SafeShellCommand.gitHardeningEnvironment["GIT_CONFIG_KEY_0"], "core.fsmonitor")
    }

    func testHarnessNudgesAreNotSavedIntoTheModelContext() {
        let kept = ChatMessage(role: .user, content: "fix the bug")
        let nudges = [
            ChatMessage(role: .user, content: "[System Command]: call a tool"),
            ChatMessage(role: .user, content: "[System]: MCP calls have failed"),
        ]
        XCTAssertEqual(AgentRunner.droppingHarnessNudges([kept] + nudges).map(\.content), ["fix the bug"])
    }

    // MARK: - Session storage

    func testSessionsAreStoredOneFileEachAndADamagedOneDoesNotTakeTheRestWithIt() throws {
        let storage = StorageService.shared
        let store = SessionStore()
        let a = Session(id: "dr-a-\(UUID().uuidString)", workspaceId: "w", title: "A", agentId: "x", providerId: "p", modelId: "m")
        let b = Session(id: "dr-b-\(UUID().uuidString)", workspaceId: "w", title: "B", agentId: "x", providerId: "p", modelId: "m")
        defer { store.write([], storage: storage) }
        store.write([a, b], storage: storage)
        XCTAssertEqual(store.read(storage: storage)?.map(\.title), ["A", "B"])

        // Damage A's file.
        let aFile = storage.fileURL(for: SessionStore.fileName(for: a.id))
        try "{ not json".write(to: aFile, atomically: true, encoding: .utf8)
        let fresh = SessionStore()
        XCTAssertEqual(fresh.read(storage: storage)?.map(\.title), ["B"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: aFile.deletingLastPathComponent().path)
        XCTAssertTrue(leftovers.contains { $0.contains(".corrupt-") }, "the damaged file is kept for recovery")
    }

    func testAnUnchangedSessionIsNotWrittenAgain() throws {
        let storage = StorageService.shared
        let store = SessionStore()
        let s = Session(id: "dr-c-\(UUID().uuidString)", workspaceId: "w", title: "C", agentId: "x", providerId: "p", modelId: "m")
        defer { store.write([], storage: storage) }
        store.write([s], storage: storage)
        let url = storage.fileURL(for: SessionStore.fileName(for: s.id))
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        store.write([s], storage: storage)
        let second = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(first, second)
    }
}
