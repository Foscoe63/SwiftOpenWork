import Foundation

/// Lists the files under a workspace folder, and decides whether one is safe to open in a text
/// editor.
///
/// Both artifact views used to call `contentsOfDirectory` directly, which listed the workspace
/// root only — on any real project that is a handful of dotfile-adjacent names and no source at
/// all. Worse, the editor decided "is this text?" by whether `String(contentsOfFile:)` threw,
/// then wrote its own error string back over the file on save.
public enum WorkspaceFileScanner {

    /// Directories that are never interesting to show and are expensive to walk.
    public static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData",
        ".venv", "venv", "__pycache__", ".next", "dist", "Pods", ".gradle",
    ]

    /// Depth 1 is the workspace root. Four levels reaches `Sources/UI/Views/Artifacts/` — deep
    /// enough for the layout this app itself uses.
    public static let defaultMaxDepth = 4

    /// A ceiling so a mistakenly-opened home directory cannot hang the scan or the list.
    public static let defaultMaxEntries = 2000

    /// Files above this size are listed but never read into the editor. 5 MB of text in a
    /// SwiftUI `TextEditor` is already painful; a 2 GB model checkpoint would take the app down.
    public static let maxEditableBytes = 5 * 1024 * 1024

    /// Workspace-relative paths, sorted, directories excluded.
    ///
    /// Sorting is case-insensitive and path-aware so files group under their folder instead of
    /// interleaving by raw byte order.
    public static func listFiles(
        at root: String,
        maxDepth: Int = defaultMaxDepth,
        maxEntries: Int = defaultMaxEntries
    ) -> [String] {
        let fm = FileManager.default
        var results: [String] = []

        func walk(_ directory: String, prefix: String, depth: Int) {
            guard depth <= maxDepth, results.count < maxEntries else { return }
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }

            for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                guard results.count < maxEntries else { return }
                guard !name.hasPrefix(".") else { continue }

                let full = (directory as NSString).appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"

                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    guard !skippedDirectories.contains(name) else { continue }
                    walk(full, prefix: relative, depth: depth + 1)
                } else {
                    results.append(relative)
                }
            }
        }

        walk(root, prefix: "", depth: 1)
        return results
    }

    /// One row of a workspace file/folder tree. `path` is workspace-relative, matching the
    /// strings `listFiles` returns, so the two can address the same file interchangeably.
    public struct FileNode: Identifiable, Hashable, Sendable {
        public var id: String { path }
        public var path: String
        public var name: String
        public var isDirectory: Bool
        /// `nil` for a file; an empty array for a directory with nothing shown in it.
        public var children: [FileNode]?
    }

    /// The same walk as `listFiles`, but keeping directory structure instead of flattening to a
    /// file list — for a tree view where folders need to be visible and expandable, not just the
    /// files under them.
    public static func listTree(
        at root: String,
        maxDepth: Int = defaultMaxDepth,
        maxEntries: Int = defaultMaxEntries
    ) -> [FileNode] {
        let fm = FileManager.default
        var entryCount = 0

        func walk(_ directory: String, prefix: String, depth: Int) -> [FileNode] {
            guard depth <= maxDepth, entryCount < maxEntries else { return [] }
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

            var nodes: [FileNode] = []
            for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                guard entryCount < maxEntries else { break }
                guard !name.hasPrefix(".") else { continue }

                let full = (directory as NSString).appendingPathComponent(name)
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"

                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    guard !skippedDirectories.contains(name) else { continue }
                    nodes.append(FileNode(
                        path: relative, name: name, isDirectory: true,
                        children: walk(full, prefix: relative, depth: depth + 1)
                    ))
                } else {
                    entryCount += 1
                    nodes.append(FileNode(path: relative, name: name, isDirectory: false, children: nil))
                }
            }
            // Folders first, then files, each alphabetical — matches Finder's default sort.
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        return walk(root, prefix: "", depth: 1)
    }

    /// What the editor is allowed to do with a file.
    public enum Content: Equatable {
        /// Decoded as UTF-8. Safe to show and to save.
        case text(String)
        /// Readable, but not UTF-8. Must not be opened in the editor or saved over.
        case binary(byteCount: Int)
        /// Readable, UTF-8 or not, but too large to hold in the editor.
        case tooLarge(byteCount: Int)
        /// Could not be read at all — permissions, a broken symlink, a race with a delete.
        case unreadable(reason: String)

        /// Only text may be written back. This is the guard that stops Save Changes replacing a
        /// PNG with whatever placeholder the editor happened to be showing.
        public var isEditable: Bool {
            if case .text = self { return true }
            return false
        }
    }

    public static func read(path: String, maxBytes: Int = maxEditableBytes) -> Content {
        let fm = FileManager.default

        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        if let size, size > maxBytes {
            return .tooLarge(byteCount: size)
        }

        guard let data = fm.contents(atPath: path) else {
            return .unreadable(reason: "The file could not be read.")
        }
        if data.count > maxBytes {
            return .tooLarge(byteCount: data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .binary(byteCount: data.count)
        }
        return .text(text)
    }

    /// Byte count in the units a person reads, for the placeholder shown instead of the editor.
    public static func humanReadableSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
