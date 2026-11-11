import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

/// Fewer rounds for the same work: wider reads, several windows in one read, and the project's
/// own build and test commands handed to the agent instead of discovered by trial.
final class RoundSavingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Reads

    func testASmallWindowIsWidenedToTheMinimum() throws {
        try write("big.txt", (1...500).map { "line \($0)" }.joined(separator: "\n"))
        let result = ToolExecutionEngine.shared.readFile(
            path: root.appendingPathComponent("big.txt").path, offset: 100, limit: 40, startTime: CFAbsoluteTimeGetCurrent()
        )
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("showing 100-299"), result.output.prefix(120).description)
        XCTAssertTrue(result.output.contains("line 299"))
    }

    func testALargerWindowIsKept() throws {
        try write("big.txt", (1...900).map { "line \($0)" }.joined(separator: "\n"))
        let result = ToolExecutionEngine.shared.readFile(
            path: root.appendingPathComponent("big.txt").path, offset: 1, limit: 400, startTime: CFAbsoluteTimeGetCurrent()
        )
        XCTAssertTrue(result.output.contains("showing 1-400"))
    }

    func testRangesAcceptStringsAndObjects() {
        let parsed = ToolExecutionEngine.readRanges(from: ["10-60", ["offset": 300, "limit": 50], "500", 7] as [Any])
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].offset, 10); XCTAssertEqual(parsed[0].limit, 51)
        XCTAssertEqual(parsed[1].offset, 300); XCTAssertEqual(parsed[1].limit, 50)
        XCTAssertEqual(parsed[2].offset, 500); XCTAssertEqual(parsed[2].limit, ToolExecutionEngine.minReadWindow)
        XCTAssertTrue(ToolExecutionEngine.readRanges(from: nil).isEmpty)
    }

    func testFileReadSchemaOffersRanges() {
        XCTAssertTrue(ToolSchemaCatalog.schemaJSON(for: "file_read").contains("\"ranges\""))
    }

    // MARK: - Build and test commands

    func testNodeScriptsUseTheProjectsPackageManager() throws {
        try write("desktop/package.json", #"{"scripts":{"test":"vitest run","build":"vite build","start":"x"}}"#)
        try write("desktop/bun.lock", "")
        let found = WorkspaceContext.detectBuildCommands(at: root.path)
        XCTAssertTrue(found.contains { $0.contains("cd desktop && bun run test") && $0.contains("vitest run") }, "\(found)")
        XCTAssertFalse(found.contains { $0.contains("start") })
    }

    func testNestedRustAndRootSwiftAreFound() throws {
        try write("desktop/src-tauri/Cargo.toml", "[package]")
        try write("Package.swift", "// swift-tools-version: 6.0")
        try write("Scripts/swift.sh", "#!/bin/sh")
        let found = WorkspaceContext.detectBuildCommands(at: root.path)
        XCTAssertTrue(found.contains("`Scripts/swift.sh test`"), "\(found)")
        XCTAssertTrue(found.contains("`cd desktop/src-tauri && cargo test`"), "\(found)")
    }

    func testDependencyFoldersAreNotSearched() throws {
        try write("node_modules/pkg/package.json", #"{"scripts":{"test":"jest"}}"#)
        XCTAssertTrue(WorkspaceContext.detectBuildCommands(at: root.path).isEmpty)
    }

    func testTheCommandsReachThePrompt() throws {
        try write("Cargo.toml", "[package]")
        let snapshot = WorkspaceContext.snapshot(folderPath: root.path, git: { _ in (nil, [], 0) })
        let block = WorkspaceContext.promptBlock(snapshot)
        XCTAssertTrue(block.contains("`cargo test`"))
        XCTAssertTrue(block.contains("do not try other runners"))
    }

    func testThePromptAsksForAScopePlan() throws {
        let source = try SourceTree.read("AgentTurn.swift")
        XCTAssertTrue(source.contains("at most three lines"))
        XCTAssertTrue(source.contains("`ranges`"))
    }
}
