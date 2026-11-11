import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

/// Memory the agent never loads is memory it never uses. These pin what reaches the prompt.
final class MemoryPromptTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "memory-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func item(_ key: String, _ content: String, ws: String = "w1", age: TimeInterval = 0,
                      category: MemoryCategory = .fact) -> MemoryItem {
        MemoryItem(workspaceId: ws, key: key, content: content, category: category,
                   createdAt: Date(timeIntervalSinceNow: -age), updatedAt: Date(timeIntervalSinceNow: -age))
    }

    func testOnlyThisWorkspacesAndSharedFactsAreLoadedNewestFirst() {
        let all = [item("old", "a", age: 100), item("other", "b", ws: "w2"), item("new", "c", age: 1),
                   item("shared", "d", ws: "default-workspace", age: 50),
                   item("recap", "e", category: .sessionSummary)]
        XCTAssertEqual(MemoryPrompt.relevant(all, workspaceId: "w1").map(\.key), ["new", "shared", "old"])
    }

    func testTheBlockListsFactsAndTellsTheModelHowToSave() {
        let block = MemoryPrompt.promptBlock(items: [item("test-cmd", "run Scripts/swift.sh test")], projectFile: nil)
        XCTAssertTrue(block.contains("- [test-cmd] run Scripts/swift.sh test"))
        XCTAssertTrue(block.contains("memory_store"))
        XCTAssertEqual(MemoryPrompt.promptBlock(items: [], projectFile: nil), "")
    }

    func testTheBlockIsBounded() {
        let many = (0..<100).map { item("k\($0)", String(repeating: "x", count: 200)) }
        let block = MemoryPrompt.promptBlock(items: many, projectFile: nil)
        XCTAssertLessThan(block.count, MemoryPrompt.maxCharacters + 1_000)
        XCTAssertFalse(block.contains("[k25]"), "no more than maxItems")
    }

    func testSavingTheSameKeyReplacesInsteadOfStacking() {
        let first = item("convention", "tabs")
        var second = item("Convention", "spaces")
        second.id = "ignored"
        let result = MemoryPrompt.upserting(second, into: [first])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].content, "spaces")
        XCTAssertEqual(result[0].id, first.id)
        XCTAssertEqual(MemoryPrompt.upserting(item("other", "x"), into: result).count, 2)
    }

    func testTheProjectFileIsWrittenReadAndReplacedByKey() throws {
        XCTAssertNil(MemoryPrompt.projectFile(workspaceRoot: root))
        XCTAssertTrue(MemoryPrompt.appendToProjectFile(key: "db", content: "uses SQLite", workspaceRoot: root))
        XCTAssertTrue(MemoryPrompt.appendToProjectFile(key: "ci", content: "GitHub Actions", workspaceRoot: root))
        XCTAssertTrue(MemoryPrompt.appendToProjectFile(key: "db", content: "uses Postgres", workspaceRoot: root))
        let text = try XCTUnwrap(MemoryPrompt.projectFile(workspaceRoot: root))
        XCTAssertTrue(text.contains("- **db**: uses Postgres"))
        XCTAssertFalse(text.contains("SQLite"))
        XCTAssertTrue(text.contains("- **ci**: GitHub Actions"))
        let block = MemoryPrompt.promptBlock(items: [], projectFile: text)
        XCTAssertTrue(block.contains(MemoryPrompt.projectFileRelativePath))
        XCTAssertTrue(block.contains("uses Postgres"))
    }

    func testTheTurnLoadsMemoryIntoTheUncachedPartOfThePrompt() throws {
        let source = try SourceTree.read("AgentTurn.swift")
        XCTAssertTrue(source.contains("MemoryPrompt.promptBlock("))
        XCTAssertTrue(source.contains("ProjectTrust.mayLoad(workspaceRoot: workspace.folderPath)\n                ? MemoryPrompt.projectFile"),
                      "a repository's memory file is an instruction source and waits for the trust decision")
        XCTAssertTrue(source.contains("memorySection, handoffSection]"))
    }

    func testMemoryStoreHasAProjectScope() throws {
        let source = try SourceTree.read("SessionToolHandlers.swift")
        XCTAssertTrue(source.contains("\"project\""))
        XCTAssertTrue(ToolSchemaCatalog.schemaJSON(for: "memory_store").contains("\"scope\""))
    }

    // MARK: - Hindsight recall

    func testARecallResultReachesThePromptAheadOfSavedFacts() {
        let block = MemoryPrompt.promptBlock(items: [item("k", "v")], projectFile: nil, recalled: "User prefers bun over npm")
        XCTAssertTrue(block.contains("Recalled from long-term memory"))
        XCTAssertTrue(block.contains("User prefers bun over npm"))
        XCTAssertLessThan(block.range(of: "bun over npm")!.lowerBound, block.range(of: "[k]")!.lowerBound)
    }

    func testAContinuePromptRecallsAgainstTheLastRealRequest() {
        let earlier = ["Add LM Studio as a local provider to the desktop app please", "Continue from where you stopped."]
        XCTAssertEqual(MemoryPrompt.recallQuery(prompt: "Continue from where you stopped. Do not repeat completed work.",
                                                previousUserMessages: earlier),
                       "Add LM Studio as a local provider to the desktop app please")
        XCTAssertEqual(MemoryPrompt.recallQuery(prompt: "fix the build", previousUserMessages: []), "fix the build")
        XCTAssertNil(MemoryPrompt.recallQuery(prompt: "  ", previousUserMessages: []))
    }

    func testFailedOrEmptyRecallsAreDropped() {
        XCTAssertNil(MemoryPrompt.usableRecall(""))
        XCTAssertNil(MemoryPrompt.usableRecall("Error: server not connected"))
        XCTAssertNil(MemoryPrompt.usableRecall("No memories found"))
        XCTAssertNil(MemoryPrompt.usableRecall("[]"))
        XCTAssertEqual(MemoryPrompt.usableRecall("- uses SwiftUI"), "- uses SwiftUI")
        XCTAssertEqual(MemoryPrompt.usableRecall(String(repeating: "x", count: 9_000))?.count, MemoryPrompt.maxRecalledCharacters)
    }

    func testTheTurnRecallsBeforeTheModelStartsAndNeverWaitsLong() throws {
        let source = try SourceTree.read("AgentTurn.swift")
        XCTAssertTrue(source.contains("await recallFromHindsight()"))
        XCTAssertTrue(source.contains("MemoryPrompt.recallTimeoutSeconds"))
        XCTAssertTrue(source.contains("agentAllowsMCP(toolId: recallTool"), "only an agent allowed to recall gets recalled memory")
        XCTAssertLessThanOrEqual(MemoryPrompt.recallTimeoutSeconds, 5)
    }
}
