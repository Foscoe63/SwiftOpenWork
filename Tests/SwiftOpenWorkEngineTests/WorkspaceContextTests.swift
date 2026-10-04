import XCTest
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

final class WorkspaceContextTests: XCTestCase {

    private func makeFolder(_ files: [String]) throws -> String {
        let root = NSTemporaryDirectory() + "wsctx-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for file in files {
            let full = root + "/" + file
            if file.hasSuffix("/") {
                try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(
                    atPath: (full as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try "x".write(toFile: full, atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    func testDetectsSwiftPackage() throws {
        let root = try makeFolder(["Package.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(WorkspaceContext.detectProjectKinds(at: root).contains("Swift package"))
    }

    func testDetectsXcodeProjectDirectory() throws {
        let root = try makeFolder(["MyApp.xcodeproj/"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(WorkspaceContext.detectProjectKinds(at: root).contains("Xcode project"))
    }

    func testWorkspaceWinsOverProject() throws {
        let root = try makeFolder(["MyApp.xcodeproj/", "MyApp.xcworkspace/"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kinds = WorkspaceContext.detectProjectKinds(at: root)
        XCTAssertTrue(kinds.contains("Xcode workspace"))
        XCTAssertFalse(kinds.contains("Xcode project"))
    }

    func testDetectsMultipleKinds() throws {
        let root = try makeFolder(["Package.swift", "Makefile"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kinds = WorkspaceContext.detectProjectKinds(at: root)
        XCTAssertTrue(kinds.contains("Swift package"))
        XCTAssertTrue(kinds.contains("Make-based build"))
    }

    func testTopLevelListsDirectoriesFirstAndHidesDotfiles() throws {
        let root = try makeFolder(["Sources/", "Tests/", "README.md", ".hidden"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let entries = WorkspaceContext.topLevelEntries(at: root)
        XCTAssertEqual(entries.prefix(2).sorted(), ["Sources/", "Tests/"])
        XCTAssertTrue(entries.contains("README.md"))
        XCTAssertFalse(entries.contains { $0.contains("hidden") })
    }

    // MARK: - Prompt rendering

    func testPromptBlockIncludesPathProjectAndGit() {
        let block = WorkspaceContext.promptBlock(
            WorkspaceContext.Snapshot(
                path: "/tmp/demo",
                projectKinds: ["Swift package"],
                topLevel: ["Sources/", "Package.swift"],
                gitBranch: "main",
                gitChanges: ["Sources/A.swift"],
                gitChangeCount: 1
            )
        )
        XCTAssertTrue(block.contains("/tmp/demo"))
        XCTAssertTrue(block.contains("Swift package"))
        XCTAssertTrue(block.contains("main"))
        XCTAssertTrue(block.contains("Sources/A.swift"))
        XCTAssertTrue(block.contains("grep"))
    }

    func testPromptBlockReportsCleanTree() {
        let block = WorkspaceContext.promptBlock(
            WorkspaceContext.Snapshot(path: "/tmp/demo", gitBranch: "main", gitChangeCount: 0)
        )
        XCTAssertTrue(block.contains("working tree clean"))
    }

    func testPromptBlockSummarisesManyChanges() {
        let changes = (1...20).map { "file\($0).swift" }
        let block = WorkspaceContext.promptBlock(
            WorkspaceContext.Snapshot(
                path: "/tmp/demo",
                gitBranch: "main",
                gitChanges: Array(changes.prefix(8)),
                gitChangeCount: 20
            )
        )
        XCTAssertTrue(block.contains("20 uncommitted"))
        XCTAssertTrue(block.contains("+12 more"))
    }

    func testPromptBlockOmitsGitForNonRepository() {
        let block = WorkspaceContext.promptBlock(
            WorkspaceContext.Snapshot(path: "/tmp/demo", projectKinds: ["Swift package"])
        )
        XCTAssertFalse(block.contains("Git:"))
        XCTAssertTrue(block.contains("Swift package"))
    }

    /// An unset workspace must render nothing, so callers can interpolate unconditionally.
    func testEmptyPathRendersNothing() {
        XCTAssertTrue(WorkspaceContext.promptBlock(WorkspaceContext.Snapshot(path: "")).isEmpty)
    }

    func testSnapshotOfMissingFolderIsInert() {
        let snapshot = WorkspaceContext.snapshot(folderPath: "/nope/does/not/exist")
        XCTAssertTrue(snapshot.projectKinds.isEmpty)
        XCTAssertTrue(snapshot.topLevel.isEmpty)
        XCTAssertNil(snapshot.gitBranch)
    }

    func testSnapshotUsesInjectedGitFacts() throws {
        let root = try makeFolder(["Package.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let snapshot = WorkspaceContext.snapshot(folderPath: root) { _ in
            (branch: "feature/x", changes: ["a.swift"], total: 3)
        }
        XCTAssertEqual(snapshot.gitBranch, "feature/x")
        XCTAssertEqual(snapshot.gitChangeCount, 3)
        XCTAssertTrue(snapshot.projectKinds.contains("Swift package"))
    }
}

final class WorkspaceContextNestedLayoutTests: XCTestCase {
    /// `MacClean/MacClean/Utilities/X.swift` was read as `MacClean/Utilities/X.swift` twice: the
    /// listing showed `MacClean/` and nothing below it.
    func testPromptShowsNestedSourceFolderAndFullPathExample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Utilities"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build/Junk"), withIntermediateDirectories: true)

        let block = WorkspaceContext.promptBlock(WorkspaceContext.snapshot(folderPath: root.path, git: { _ in (nil, [], 0) }))
        XCTAssertTrue(block.contains("`App/` contains: Utilities/"), block)
        XCTAssertTrue(block.contains("\(root.path)/App/Utilities/"), block)
        XCTAssertFalse(block.contains("`build/` contains"), block)
    }
}

final class SubAgentPromptWorkspaceTests: XCTestCase {
    /// A sub-agent was told the project was at the user's path while it ran in a worktree
    /// elsewhere, and spent its budget on paths that did not exist.
    func testSubAgentPromptCarriesWorkspaceBlock() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/SwiftOpenWorkEngineTests/WorkspaceContextTests.swift",
            with: "Sources/SwiftOpenWorkEngine/Agents/SubAgentExecutor.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("WorkspaceContext.promptBlock(WorkspaceContext.snapshot(folderPath: effectiveWorkspace.folderPath))"))
    }
}
