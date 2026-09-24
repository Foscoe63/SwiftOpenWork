import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// File tools must fail closed: a malformed call may not destroy anything.
final class FileToolSafetyTests: XCTestCase {

    private var root = ""
    private var workspace: Workspace!
    private let agent = Agent(name: "Test")

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "safety-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Test", folderPath: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func run(_ tool: String, _ args: [String: Any] = [:]) async -> ToolExecutionResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return await ToolExecutionEngine.shared.execute(toolName: tool, argumentsJson: json, workspace: workspace, currentAgent: agent)
    }

    private func path(_ name: String) -> String { root + "/" + name }
    private func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path(name) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path(name), atomically: true, encoding: .utf8)
    }
    private func read(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }

    // MARK: file_write

    func testWriteWithoutContentDoesNotWipeTheFile() async throws {
        try write("a.txt", "precious")
        let result = await run("file_write", ["path": "a.txt"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(read("a.txt"), "precious")
    }

    func testAnExplicitEmptyStringStillWritesAnEmptyFile() async throws {
        let result = await run("file_write", ["path": "empty.txt", "content": ""])
        XCTAssertTrue(result.success)
        XCTAssertEqual(read("empty.txt"), "")
    }

    func testObjectContentIsWrittenAsJSON() async throws {
        let result = await run("file_write", ["path": "package.json", "content": ["name": "app", "scripts": ["dev": "vite"]]])
        XCTAssertTrue(result.success, result.error ?? "")
        let text = try XCTUnwrap(read("package.json"))
        XCTAssertTrue(text.contains("\"name\" : \"app\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testWriteToADirectoryPathIsRefused() async throws {
        try write("d/x.txt", "x")
        let result = await run("file_write", ["path": "d", "content": "y"])
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("directory"))
    }

    func testAlternativeContentKeyStillWorks() async throws {
        let result = await run("write_file", ["file_path": "b.txt", "text": "hi"])
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(read("b.txt"), "hi")
    }

    // MARK: file_delete

    func testDeleteWithoutPathCannotRemoveTheWorkspace() async throws {
        try write("keep.txt", "k")
        let result = await run("file_delete", [:])
        XCTAssertFalse(result.success)
        XCTAssertEqual(read("keep.txt"), "k")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root))
    }

    func testDeleteRefusesTheWorkspaceRootByName() {
        XCTAssertNotNil(ToolExecutionEngine.refusedDeleteTarget(root, workspaceRoot: root))
        XCTAssertNotNil(ToolExecutionEngine.refusedDeleteTarget((root as NSString).deletingLastPathComponent, workspaceRoot: root))
        XCTAssertNil(ToolExecutionEngine.refusedDeleteTarget(root + "/sub/file.txt", workspaceRoot: root))
    }

    // MARK: move / copy

    func testMovingAMissingSourceLeavesTheDestinationAlone() async throws {
        try write("dest.txt", "keep me")
        let result = await run("file_move", ["source": "typo.txt", "destination": "dest.txt"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(read("dest.txt"), "keep me", "the destination used to be deleted before the source was checked")
    }

    func testMovingAFileOntoItselfDoesNotDeleteIt() async throws {
        try write("a.txt", "same")
        let result = await run("file_move", ["source": "a.txt", "destination": "./a.txt"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(read("a.txt"), "same")
    }

    func testCopyStillOverwritesAnExistingFile() async throws {
        try write("a.txt", "new")
        try write("b.txt", "old")
        let result = await run("file_copy", ["source": "a.txt", "destination": "b.txt"])
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(read("b.txt"), "new")
    }

    // MARK: file_list / file_read on folders

    func testListMarksFoldersAndShowsUsefulDotfiles() async throws {
        try write("src/a.swift", "x")
        try write(".github/workflows/ci.yml", "x")
        try write(".env.example", "x")
        try write(".gitignore", "x")
        try FileManager.default.createDirectory(atPath: path(".git"), withIntermediateDirectories: true)
        let result = await run("file_list", ["path": "."])
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("src/"))
        XCTAssertTrue(result.output.contains(".github/"))
        XCTAssertTrue(result.output.contains(".env.example"))
        XCTAssertTrue(result.output.contains(".gitignore"))
        XCTAssertFalse(result.output.contains(".git/"), "the repository's own folder is noise")
    }

    func testListingAFileSaysSo() async throws {
        try write("a.txt", "x")
        let result = await run("file_list", ["path": "a.txt"])
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("is a file"))
    }

    func testReadingAFolderListsItInsteadOfClaimingItIsBinary() async throws {
        try write("skills/one/SKILL.md", "body")
        let result = await run("file_read", ["path": "skills"])
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("is a directory"))
        XCTAssertTrue(result.output.contains("one/"))
        XCTAssertFalse(result.output.contains("binary"))
    }

    // MARK: edit tools

    func testEditingAFolderOrMissingFileGivesUsableErrors() async throws {
        try write("d/x.txt", "x")
        let folder = await run("edit_file", ["path": "d", "old_string": "a", "new_string": "b"])
        XCTAssertTrue((folder.error ?? "").contains("directory"), folder.error ?? "")
        let missing = await run("edit_file", ["path": "nope.txt", "old_string": "a", "new_string": "b"])
        XCTAssertTrue((missing.error ?? "").contains("does not exist"), missing.error ?? "")
        let noop = await run("edit_file", ["path": "d/x.txt", "old_string": "x", "new_string": "x"])
        XCTAssertTrue((noop.error ?? "").contains("identical"), noop.error ?? "")
    }

    // MARK: naming

    func testLooseToolNamesReachTheRealTool() async throws {
        try write("a.txt", "hello")
        let result = await run("read", ["file_path": "a.txt"])
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.output.contains("hello"))
    }

    func testAnInventedToolGetsSuggestionsNotAnMcpError() async throws {
        let result = await run("file_reed", ["path": "a.txt"])
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("file_read"), result.error ?? "")
    }
}
