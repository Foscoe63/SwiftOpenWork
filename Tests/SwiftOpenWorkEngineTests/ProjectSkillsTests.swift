import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Skills that live in the repository, rather than in the app's global `skills.json`.
final class ProjectSkillsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("project-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSkill(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Discovery

    func testLoadsNestedSkillFilesWithFrontMatter() throws {
        try writeSkill(".swiftopenwork/skills/release-checklist/SKILL.md", """
        ---
        name: Release checklist
        description: What this project does before tagging.
        ---

        1. `swift test` is green.
        """)

        let skills = ProjectSkills.load(workspacePath: root.path)
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "Release checklist")
        XCTAssertEqual(skills[0].description, "What this project does before tagging.")
        XCTAssertEqual(skills[0].source, .project)
        XCTAssertEqual(skills[0].category, "Project")
        XCTAssertTrue(skills[0].content.hasPrefix("1. `swift test`"))
        XCTAssertFalse(skills[0].content.contains("---"), "front matter must not reach the prompt")
    }

    func testFallsBackToFolderNameAndFirstLine() throws {
        try writeSkill(".swiftopenwork/skills/db_migrations/SKILL.md", """
        # Migrations here are always reversible

        Write the down step first.
        """)

        let skills = ProjectSkills.load(workspacePath: root.path)
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "Db Migrations")
        XCTAssertEqual(skills[0].description, "Migrations here are always reversible")
    }

    func testTopLevelMarkdownIsASkillButReadmeIsNot() throws {
        try writeSkill(".swiftopenwork/skills/house-style.md", "Two-space indents, always.")
        try writeSkill(".swiftopenwork/skills/README.md", "How this folder works.")

        let skills = ProjectSkills.load(workspacePath: root.path)
        XCTAssertEqual(skills.map(\.name), ["House Style"])
    }

    func testEmptySkillFileIsIgnored() throws {
        try writeSkill(".swiftopenwork/skills/blank/SKILL.md", "---\nname: Blank\n---\n\n   \n")
        XCTAssertTrue(ProjectSkills.load(workspacePath: root.path).isEmpty)
    }

    func testDisabledSkillIsLoadedButKeptOutOfThePrompt() throws {
        try writeSkill(".swiftopenwork/skills/draft/SKILL.md", """
        ---
        name: Draft
        enabled: false
        ---

        Not ready.
        """)

        let skills = ProjectSkills.load(workspacePath: root.path)
        XCTAssertEqual(skills.count, 1, "settings must still list it, or the file looks broken")
        XCTAssertFalse(skills[0].isEnabled)
        XCTAssertEqual(ProjectSkills.promptBlock(skills), "")
    }

    // MARK: - Legacy folders

    func testLegacyFoldersAreReadAndTheCurrentOneWins() throws {
        try writeSkill(".openwork/skills/shared/SKILL.md", "---\nname: Shared\n---\n\nOld copy.")
        try writeSkill(".claude/skills/only-there/SKILL.md", "---\nname: Only There\n---\n\nBody.")
        try writeSkill(".swiftopenwork/skills/shared/SKILL.md", "---\nname: Shared\n---\n\nNew copy.")

        let skills = ProjectSkills.load(workspacePath: root.path)
        XCTAssertEqual(skills.map(\.name), ["Only There", "Shared"])
        let shared = try XCTUnwrap(skills.first(where: { $0.name == "Shared" }))
        XCTAssertTrue(shared.content.contains("New copy."), "\(ProjectSkills.relativePath) must win")
    }

    // MARK: - Bounds

    func testLongSkillIsClipped() throws {
        let body = String(repeating: "x", count: ProjectSkills.maxCharacters + 500)
        try writeSkill(".swiftopenwork/skills/huge/SKILL.md", body)
        let skills = ProjectSkills.load(workspacePath: root.path)
        XCTAssertEqual(skills.first?.content.count, ProjectSkills.maxCharacters)
    }

    func testSkillCountIsCapped() throws {
        for index in 0..<(ProjectSkills.maxSkills + 10) {
            try writeSkill(".swiftopenwork/skills/skill-\(index)/SKILL.md", "Body \(index).")
        }
        XCTAssertEqual(ProjectSkills.load(workspacePath: root.path).count, ProjectSkills.maxSkills)
    }

    // MARK: - Folder handling

    func testMissingWorkspaceOrFolderLoadsNothing() {
        XCTAssertTrue(ProjectSkills.load(workspacePath: "").isEmpty)
        XCTAssertTrue(ProjectSkills.load(workspacePath: root.path).isEmpty)
        XCTAssertTrue(ProjectSkills.existingFolders(in: root.path).isEmpty)
    }

    func testEnsureFolderCreatesItOnceWithAReadme() throws {
        let created = try ProjectSkills.ensureFolder(in: root.path)
        XCTAssertEqual(created, ProjectSkills.folder(in: root.path))

        let readme = (created as NSString).appendingPathComponent("README.md")
        try "edited by hand".write(toFile: readme, atomically: true, encoding: .utf8)
        _ = try ProjectSkills.ensureFolder(in: root.path)
        XCTAssertEqual(
            try String(contentsOfFile: readme, encoding: .utf8),
            "edited by hand",
            "a second call must not overwrite the user's README"
        )
        XCTAssertTrue(ProjectSkills.load(workspacePath: root.path).isEmpty, "the README is not a skill")
    }

    // MARK: - Prompt

    func testPromptBlockNamesTheFolderAndEachSkill() throws {
        try writeSkill(".swiftopenwork/skills/a/SKILL.md", "---\nname: A\ndescription: Does A.\n---\n\nBody.")
        let block = ProjectSkills.promptBlock(ProjectSkills.load(workspacePath: root.path))
        XCTAssertTrue(block.contains(ProjectSkills.relativePath))
        XCTAssertTrue(block.contains("- **A**: Does A."))
    }

    /// The block told the model to read "the path listed" and listed none, so it read the folder.
    func testPromptBlockListsTheFileToRead() throws {
        try writeSkill(".swiftopenwork/skills/a/SKILL.md", "---\nname: A\ndescription: Does A.\n---\n\nBody.")
        let skills = ProjectSkills.load(workspacePath: root.path)
        let block = ProjectSkills.promptBlock(skills)
        let path = try XCTUnwrap(skills.first?.filePath)
        XCTAssertTrue(block.contains("file: `\(path)`"), block)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testReadingASkillsFolderListsTheSkillFiles() throws {
        try writeSkill(".swiftopenwork/skills/a/SKILL.md", "Body A")
        try writeSkill(".swiftopenwork/skills/b/SKILL.md", "Body B")
        let folder = ProjectSkills.folder(in: root.path)
        let listing = ToolExecutionEngine.directoryListing(atPath: folder, displayPath: folder)
        XCTAssertTrue(listing.contains("is a directory"))
        XCTAssertTrue(listing.contains("a/  → SKILL.md"))
        XCTAssertTrue(listing.contains("\(folder)/a/SKILL.md"), "the suggested path must be a file, not another folder")
        XCTAssertFalse(listing.contains("binary"))
    }

    func testPromptBlockIsEmptyWithoutSkills() {
        XCTAssertEqual(ProjectSkills.promptBlock([]), "")
    }

    // MARK: - Wiring

    func testAgentRunnerBuildsTheProjectSkillsBlock() throws {
        let source = try SourceTree.read("AgentRunner.swift")
        XCTAssertTrue(
            source.contains("ProjectSkills.promptBlock"),
            "project skills must reach the system prompt, not just the settings list"
        )
    }
}
