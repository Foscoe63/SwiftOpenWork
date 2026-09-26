import Foundation
import SwiftOpenWorkCore

/// Skills that live in the repository, next to the code they describe.
///
/// The app's own skills are global: one `skills.json` in Application Support, shared by every
/// workspace. That is wrong for anything repo-specific — a release checklist, the way this
/// project writes migrations — because the skill is only meaningful inside that checkout, and it
/// should travel with the checkout when it is cloned or handed to someone else.
///
/// So a project carries its own `.swiftopenwork/skills/` folder, read fresh each turn. Nothing is
/// imported into `skills.json`: the files on disk are the state, which is what makes them
/// reviewable in a pull request.
public enum ProjectSkills {

    /// The folder this app writes and reads, relative to the workspace root.
    public static let relativePath = ".swiftopenwork/skills"

    /// Read as well, never written: the 1.1 name, so a checkout set up against it keeps working,
    /// and the folder other tools use, so a repository already carrying skills is not made to
    /// keep a second copy.
    public static let legacyRelativePaths = [AppIdentity.legacySkillsRelativePath, ".claude/skills"]

    /// Past this a skill is clipped — a runaway file must not crowd out the conversation.
    public static let maxCharacters = 8_000

    /// Past this the rest are ignored, so a folder someone pointed at a skills monorepo cannot
    /// bury the system prompt.
    public static let maxSkills = 48

    // MARK: - Locations

    /// Absolute path of the folder this app writes, whether or not it exists.
    public static func folder(in workspacePath: String) -> String {
        (workspacePath as NSString).appendingPathComponent(relativePath)
    }

    /// Every folder scanned for this workspace, most preferred first, existing ones only.
    public static func existingFolders(
        in workspacePath: String,
        fileManager: FileManager = .default
    ) -> [String] {
        guard !workspacePath.isEmpty else { return [] }
        return ([relativePath] + legacyRelativePaths)
            .map { (workspacePath as NSString).appendingPathComponent($0) }
            .filter { path in
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            }
    }

    /// Create `.swiftopenwork/skills/` with a README explaining the layout. Returns the folder.
    ///
    /// The README is what stops the folder from being deleted as mystery clutter by the next
    /// person who opens the repository.
    @discardableResult
    public static func ensureFolder(
        in workspacePath: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let path = folder(in: workspacePath)
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        let readme = (path as NSString).appendingPathComponent("README.md")
        guard !fileManager.fileExists(atPath: readme) else { return path }
        try readmeContent.write(toFile: readme, atomically: true, encoding: .utf8)
        return path
    }

    static let readmeContent = """
    # Project skills

    Skills in this folder are loaded by \(AppIdentity.displayName) for **this repository only**,
    on top of the global skills in Settings → Skills & MCP. They are read from disk every turn,
    so an edit here takes effect on the next message — nothing has to be re-imported.

    Layout — one folder per skill:

        .swiftopenwork/skills/
          release-checklist/
            SKILL.md
          migrations/
            SKILL.md

    A single `some-skill.md` file at the top level works too.

    Each `SKILL.md` may open with YAML front matter:

        ---
        name: Release checklist
        description: The steps this project takes before tagging a release.
        enabled: true
        ---

        1. `swift test` is green on main.
        2. ...

    `name` defaults to the folder name and `description` to the first line of the body.
    Set `enabled: false` to keep a skill in the repository without loading it.
    """

    // MARK: - Loading

    /// Skills found for this workspace, sorted by name.
    ///
    /// Disabled skills are included — the Settings list shows them greyed out, and filtering here
    /// would make a `enabled: false` file look like a parse failure.
    public static func load(
        workspacePath: String,
        fileManager: FileManager = .default
    ) -> [Skill] {
        var found: [Skill] = []
        var seenNames: Set<String> = []

        for directory in existingFolders(in: workspacePath, fileManager: fileManager) {
            for file in skillFiles(in: directory, fileManager: fileManager) {
                guard found.count < maxSkills else { return found.sorted { $0.name < $1.name } }
                guard let skill = parse(file: file, in: directory, fileManager: fileManager) else { continue }
                // `.swiftopenwork` wins over `.openwork` and `.claude` for the same skill name,
                // so a migrated repository does not carry both copies into the prompt.
                guard seenNames.insert(skill.name.lowercased()).inserted else { continue }
                found.append(skill)
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    /// Markdown files that are candidate skills: `<slug>/SKILL.md`, then top-level `*.md`.
    /// `README.md` is documentation for the folder itself, never a skill.
    static func skillFiles(
        in directory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let entries = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var files: [String] = []
        for entry in entries where !entry.hasPrefix(".") {
            let full = (directory as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let nested = (full as NSString).appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: nested) { files.append(nested) }
            } else if entry.lowercased().hasSuffix(".md"), entry.lowercased() != "readme.md" {
                files.append(full)
            }
        }
        return files
    }

    static func parse(
        file: String,
        in directory: String,
        fileManager: FileManager = .default
    ) -> Skill? {
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let parsed = splitFrontMatter(raw)
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let isNestedSkillFile = (file as NSString).lastPathComponent.lowercased() == "skill.md"
        let fallbackName = isNestedSkillFile
            ? ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            : ((file as NSString).deletingPathExtension as NSString).lastPathComponent

        let name = parsed.fields["name"] ?? humanise(fallbackName)
        let description = parsed.fields["description"] ?? firstLine(of: body)
        let enabled = (parsed.fields["enabled"].map { !isFalse($0) }) ?? true
        let clipped = body.count > maxCharacters ? String(body.prefix(maxCharacters)) : body

        // The path is the identity: the same file keeps its id across reloads, and two skills of
        // the same name in different folders do not collide.
        let relative = file.hasPrefix(directory)
            ? String(file.dropFirst(directory.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : (file as NSString).lastPathComponent

        return Skill(
            id: "project:\(relative)",
            name: name,
            description: description,
            category: "Project",
            content: clipped,
            source: .project,
            filePath: file,
            isEnabled: enabled
        )
    }

    /// The prompt block. Empty when the project has no skills, so callers can interpolate
    /// unconditionally.
    public static func promptBlock(_ skills: [Skill]) -> String {
        let enabled = skills.filter(\.isEnabled)
        guard !enabled.isEmpty else { return "" }
        let lines = enabled.map { skill -> String in
            let preview = skill.description.isEmpty
                ? String(skill.content.prefix(160))
                : skill.description
            // The path is the whole point of this line. The block used to tell the model to
            // `file_read` "the path listed" while listing none, so it guessed the folder and read
            // a directory — which failed, was retried, and tripped the repeated-failure breaker.
            guard let path = skill.filePath, !path.isEmpty else { return "- **\(skill.name)**: \(preview)" }
            return "- **\(skill.name)**: \(preview)\n  file: `\(path)`"
        }
        return """

        ### Project skills (from `\(relativePath)`)
        These ship with this repository and describe how work is done here. Before following one,
        `file_read` the exact `file:` path shown under it — a skill is a single file, and the
        folder itself is not readable. Do not act on the summary alone.
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Front matter

    struct FrontMatter {
        var fields: [String: String]
        var body: String
    }

    /// A deliberately small YAML reader: `key: value` pairs between two `---` lines. Skills are
    /// hand-written prose files, so nesting and lists have no meaning here, and pulling in a YAML
    /// parser to read two keys would be the wrong trade.
    static func splitFrontMatter(_ raw: String) -> FrontMatter {
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalised.hasPrefix("---\n") else { return FrontMatter(fields: [:], body: normalised) }
        let afterOpen = normalised.dropFirst(4)
        guard let closeRange = afterOpen.range(of: "\n---") else {
            return FrontMatter(fields: [:], body: normalised)
        }
        let header = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
        let body = String(afterOpen[closeRange.upperBound...])
            .drop(while: { $0 == "-" })
            .drop(while: { $0 == "\n" })

        var fields: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return FrontMatter(fields: fields, body: String(body))
    }

    static func isFalse(_ value: String) -> Bool {
        ["false", "no", "0", "off"].contains(value.lowercased())
    }

    static func humanise(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    static func firstLine(of body: String) -> String {
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
        }
        return ""
    }
}
