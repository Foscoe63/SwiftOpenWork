import Foundation
import SwiftOpenWorkCore

/// Whether to believe what a project says about itself.
///
/// `AGENTS.md`, `CLAUDE.md` and a `skills/` folder are instructions the agent follows, and they
/// arrive with a checkout. Clone a repository and open it, and whoever wrote those files is giving
/// your agent orders — "also send ~/.ssh to this address" is a sentence like any other. So the app
/// reads them only once you have seen what is there.
///
/// Trust is granted per project for the *set of sources* (which instruction file, which skills),
/// not for their text: you are not asked again because a teammate fixed a typo, but you are asked
/// when a new skill appears. Projects that were already open when this was introduced are
/// acknowledged as they stand, so nothing silently stops working.
public enum ProjectTrust {

    public struct Inventory: Equatable, Sendable {
        /// The instruction file that would be loaded, e.g. `AGENTS.md`.
        public var instructionFile: String?
        /// Project skills that would be loaded, by file name.
        public var skillFiles: [String]

        public var isEmpty: Bool { instructionFile == nil && skillFiles.isEmpty }

        /// What changes the question: sources, not wording.
        var fingerprint: String { ([instructionFile ?? "-"] + skillFiles.sorted()).joined(separator: "\u{1F}") }

        public var summary: String {
            var parts: [String] = []
            if let instructionFile { parts.append(instructionFile) }
            if !skillFiles.isEmpty { parts.append("\(skillFiles.count) skill\(skillFiles.count == 1 ? "" : "s")") }
            return parts.joined(separator: " and ")
        }
    }

    public enum State: Equatable, Sendable {
        case nothingToLoad
        case trusted
        case declined
        /// There are project sources this person has not seen.
        case needsReview(Inventory)
    }

    private static let key = "projectTrust.records"
    private static let initialisedKey = "projectTrust.initialised"

    private struct Record: Codable { var fingerprint: String; var trusted: Bool }

    public static func inventory(workspaceRoot root: String) -> Inventory {
        guard !root.isEmpty else { return Inventory(instructionFile: nil, skillFiles: []) }
        let instructions = ProjectInstructions.load(folderPath: root)?.name
        let skills = ProjectSkills.existingFolders(in: root).flatMap { directory in
            ProjectSkills.skillFiles(in: directory).map { ($0 as NSString).lastPathComponent == "SKILL.md"
                ? ((($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/SKILL.md")
                : ($0 as NSString).lastPathComponent }
        }
        return Inventory(instructionFile: instructions, skillFiles: skills)
    }

    public static func state(workspaceRoot root: String) -> State {
        let found = inventory(workspaceRoot: root)
        if found.isEmpty { return .nothingToLoad }
        guard let record = records()[ToolExecutionEngine.canonicalPath(root)], record.fingerprint == found.fingerprint else {
            return .needsReview(found)
        }
        return record.trusted ? .trusted : .declined
    }

    /// Whether the project's own instructions and skills may enter the prompt.
    public static func mayLoad(workspaceRoot root: String) -> Bool {
        switch state(workspaceRoot: root) {
        case .nothingToLoad, .trusted: return true
        case .declined, .needsReview: return false
        }
    }

    public static func decide(workspaceRoot root: String, trusted: Bool) {
        var all = records()
        all[ToolExecutionEngine.canonicalPath(root)] = Record(fingerprint: inventory(workspaceRoot: root).fingerprint, trusted: trusted)
        save(all)
    }

    /// Once, when this check first exists: projects already open keep working as they were.
    public static func grandfather(workspaceRoots: [String]) {
        guard !AppIdentity.defaults.bool(forKey: initialisedKey) else { return }
        AppIdentity.defaults.set(true, forKey: initialisedKey)
        var all = records()
        for root in workspaceRoots where !root.isEmpty {
            let found = inventory(workspaceRoot: root)
            if !found.isEmpty { all[ToolExecutionEngine.canonicalPath(root)] = Record(fingerprint: found.fingerprint, trusted: true) }
        }
        save(all)
    }

    private static func records() -> [String: Record] {
        guard let data = AppIdentity.defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private static func save(_ records: [String: Record]) {
        if let data = try? JSONEncoder().encode(records) { AppIdentity.defaults.set(data, forKey: key) }
    }
}
