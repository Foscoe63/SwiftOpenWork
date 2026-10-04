import Foundation
import SwiftOpenWorkCore

/// Facts about the workspace the agent is working in, rendered for the system prompt.
///
/// Without this the model is told which tools exist but not where it is, what kind of project it
/// is, or what is already modified — so it guesses paths, guesses build commands, and re-derives
/// the layout with tool calls every turn.
public enum WorkspaceContext {

    public struct Snapshot: Sendable, Equatable {
        public var path: String
        /// Human labels for what kind of project this is ("Swift package", "Node project", …).
        public var projectKinds: [String]
        /// Top-level entries, directories first.
        public var topLevel: [String]
        /// Children of the first top-level folders, so a nested layout (`App/App/Utilities/`) is
        /// visible up front instead of being found by failed reads. Folder name to its entries.
        public var nested: [(folder: String, entries: [String])]
        public var gitBranch: String?
        /// Paths reported by `git status --porcelain`, already trimmed to a useful count.
        public var gitChanges: [String]
        public var gitChangeCount: Int

        public static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.path == b.path && a.projectKinds == b.projectKinds && a.topLevel == b.topLevel
                && a.nested.map { [$0.folder] + $0.entries } == b.nested.map { [$0.folder] + $0.entries }
                && a.gitBranch == b.gitBranch && a.gitChanges == b.gitChanges && a.gitChangeCount == b.gitChangeCount
        }

        public init(
            path: String,
            projectKinds: [String] = [],
            topLevel: [String] = [],
            nested: [(folder: String, entries: [String])] = [],
            gitBranch: String? = nil,
            gitChanges: [String] = [],
            gitChangeCount: Int = 0
        ) {
            self.path = path
            self.projectKinds = projectKinds
            self.topLevel = topLevel
            self.nested = nested
            self.gitBranch = gitBranch
            self.gitChanges = gitChanges
            self.gitChangeCount = gitChangeCount
        }
    }

    /// Marker files that identify a project type, in the order they should be reported.
    public static let markers: [(file: String, label: String)] = [
        ("Package.swift", "Swift package"),
        ("project.yml", "XcodeGen project (run `xcodegen generate` after editing)"),
        ("Cargo.toml", "Rust crate"),
        ("go.mod", "Go module"),
        ("pyproject.toml", "Python project"),
        ("requirements.txt", "Python project"),
        ("package.json", "Node project"),
        ("Gemfile", "Ruby project"),
        ("pom.xml", "Maven project"),
        ("build.gradle", "Gradle project"),
        ("Makefile", "Make-based build"),
        ("CMakeLists.txt", "CMake project"),
    ]

    public static func detectProjectKinds(
        at path: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var kinds: [String] = []
        for marker in markers where fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(marker.file)) {
            kinds.append(marker.label)
        }
        // An .xcodeproj/.xcworkspace is a directory, so it needs its own pass.
        if let entries = try? fileManager.contentsOfDirectory(atPath: path) {
            if entries.contains(where: { $0.hasSuffix(".xcworkspace") }) {
                kinds.append("Xcode workspace")
            } else if entries.contains(where: { $0.hasSuffix(".xcodeproj") }) {
                kinds.append("Xcode project")
            }
        }
        return kinds
    }

    public static func topLevelEntries(
        at path: String,
        limit: Int = 24,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return [] }
        let visible = entries.filter { !$0.hasPrefix(".") }
        let annotated = visible.map { name -> (String, Bool) in
            var isDir: ObjCBool = false
            let full = (path as NSString).appendingPathComponent(name)
            fileManager.fileExists(atPath: full, isDirectory: &isDir)
            return (name, isDir.boolValue)
        }
        // Directories first — they are what the agent needs to navigate.
        let sorted = annotated.sorted {
            $0.1 == $1.1 ? $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending : $0.1
        }
        return sorted.prefix(limit).map { $0.1 ? "\($0.0)/" : $0.0 }
    }

    /// Entries of the first few top-level folders that hold source, skipping build output and
    /// folders that only hold project metadata.
    public static func nestedEntries(
        at path: String,
        topLevel: [String],
        folders: Int = 6,
        limit: Int = 12,
        fileManager: FileManager = .default
    ) -> [(folder: String, entries: [String])] {
        let skipped: Set<String> = ["build", "node_modules", "DerivedData", "Pods", "Resources", "docs"]
        var result: [(folder: String, entries: [String])] = []
        for entry in topLevel where entry.hasSuffix("/") {
            let name = String(entry.dropLast())
            if skipped.contains(name) || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") { continue }
            let children = topLevelEntries(at: (path as NSString).appendingPathComponent(name), limit: limit, fileManager: fileManager)
            if !children.isEmpty { result.append((entry, children)) }
            if result.count >= folders { break }
        }
        return result
    }

    /// Render the prompt block. Returns an empty string when there is no usable workspace, so the
    /// caller can interpolate it unconditionally.
    public static func promptBlock(_ snapshot: Snapshot) -> String {
        guard !snapshot.path.isEmpty else { return "" }
        var lines = ["", "### Workspace", "Path: `\(snapshot.path)`"]

        if !snapshot.projectKinds.isEmpty {
            lines.append("Project: \(snapshot.projectKinds.joined(separator: ", "))")
        }
        if let branch = snapshot.gitBranch {
            if snapshot.gitChangeCount == 0 {
                lines.append("Git: on `\(branch)`, working tree clean")
            } else {
                let shown = snapshot.gitChanges.joined(separator: ", ")
                let more = snapshot.gitChangeCount > snapshot.gitChanges.count
                    ? " (+\(snapshot.gitChangeCount - snapshot.gitChanges.count) more)"
                    : ""
                lines.append("Git: on `\(branch)`, \(snapshot.gitChangeCount) uncommitted: \(shown)\(more)")
            }
        }
        if !snapshot.topLevel.isEmpty {
            lines.append("Top level: \(snapshot.topLevel.joined(separator: "  "))")
        }
        for item in snapshot.nested {
            lines.append("`\(item.folder)` contains: \(item.entries.joined(separator: "  "))")
        }
        if let first = snapshot.nested.first(where: { !$0.entries.isEmpty }) {
            lines.append("Paths are written in full from the workspace path, e.g. `\(snapshot.path)/\(first.folder)\(first.entries[0])`.")
        }
        lines.append(
            "Relative paths in file tools resolve against this folder. Use `grep` and `glob` to "
            + "locate code before reading it — do not guess paths."
        )
        return lines.joined(separator: "\n")
    }

    /// Collect everything above. Git facts are best-effort: a non-repo folder simply omits them.
    public static func snapshot(
        folderPath: String,
        fileManager: FileManager = .default,
        git: (String) -> (branch: String?, changes: [String], total: Int) = gitFacts
    ) -> Snapshot {
        guard !folderPath.isEmpty, fileManager.fileExists(atPath: folderPath) else {
            return Snapshot(path: folderPath)
        }
        let facts = git(folderPath)
        let topLevel = topLevelEntries(at: folderPath, fileManager: fileManager)
        return Snapshot(
            path: folderPath,
            projectKinds: detectProjectKinds(at: folderPath, fileManager: fileManager),
            topLevel: topLevel,
            nested: nestedEntries(at: folderPath, topLevel: topLevel, fileManager: fileManager),
            gitBranch: facts.branch,
            gitChanges: facts.changes,
            gitChangeCount: facts.total
        )
    }

    /// Branch and dirty-file summary, or nils when this is not a git repository.
    public static func gitFacts(folderPath: String) -> (branch: String?, changes: [String], total: Int) {
        guard let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: folderPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !branch.isEmpty else {
            return (nil, [], 0)
        }
        let status = runGit(["status", "--porcelain"], in: folderPath) ?? ""
        let paths = status
            .split(separator: "\n")
            .map { String($0.dropFirst(3)) }
            .filter { !$0.isEmpty }
        return (branch, Array(paths.prefix(8)), paths.count)
    }

    private static func runGit(_ args: [String], in folder: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.environment = ToolExecutionEngine.defaultEnvironment()

        let out = Pipe()
        process.standardOutput = out
        // git chatters to stderr on non-repos; nullDevice avoids both the noise and a pipe that
        // nobody drains.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
