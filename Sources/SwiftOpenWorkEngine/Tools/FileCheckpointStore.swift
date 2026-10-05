import Foundation

/// Undo for agent file edits.
///
/// An agent that can write files needs a way back. Git covers committed work, but a vibe-coding
/// turn typically starts from a dirty tree and makes several edits before anyone looks at them —
/// so "restore what this turn changed" cannot be `git checkout`. This records each file's prior
/// contents the first time a turn touches it, and can put them all back.
public actor FileCheckpointStore {
    public static let shared = FileCheckpointStore()

    /// One file as it was before the current turn first modified it.
    public struct Entry: Sendable {
        /// nil means the file did not exist, so reverting deletes it.
        public var previousContents: String?
        public var firstTouched: Date
    }

    public struct Summary: Sendable, Equatable {
        public var created: [String]
        public var modified: [String]
        public var deleted: [String]

        public var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty }
        public var totalCount: Int { created.count + modified.count + deleted.count }
    }

    public struct RevertOutcome: Sendable, Equatable {
        public var restored: [String]
        public var removed: [String]
        public var failed: [String]
    }

    /// One session's checkpoint window: its current turn's entries.
    private struct Window {
        var entries: [String: Entry] = [:]
        var label: String?
    }

    /// Windows by session id. This used to be one global window, so a Loop, automation or
    /// Shortcut run starting mid-turn wiped the foreground chat's undo, and `revert_changes` in
    /// either run reverted the other's edits.
    private var windows: [String: Window] = [:]

    /// The window a call belongs to: the session passed, else the agent run it is part of (tool
    /// calls run inside `AgentRunContext`), else a shared default for callers with neither.
    private func key(_ session: String?) -> String {
        session ?? AgentRunContext.current?.sessionId ?? ""
    }

    private func entries(_ session: String?) -> [String: Entry] {
        windows[key(session)]?.entries ?? [:]
    }

    private init() {}

    // MARK: - Turn lifecycle

    /// Start a new checkpoint window, discarding the previous one.
    ///
    /// Undo is deliberately scoped to the most recent turn: an agent that can silently roll back
    /// work from ten turns ago is more dangerous than one that cannot roll back at all.
    public func beginTurn(label: String? = nil, session: String? = nil) {
        windows[key(session)] = Window(label: label)
    }

    public func currentTurnLabel(session: String? = nil) -> String? { windows[key(session)]?.label }

    /// Forget a session's window, when the session is deleted.
    public func discard(session: String) {
        windows.removeValue(forKey: session)
    }

    // MARK: - Recording

    /// Capture a file's current state, if this turn has not already captured it.
    ///
    /// Only the *first* capture per path is kept: the point of reference is where the turn
    /// started, not the state between two edits within it.
    public func record(path: String, session: String? = nil, fileManager: FileManager = .default) {
        let k = key(session)
        guard windows[k]?.entries[path] == nil else { return }
        let existing = fileManager.fileExists(atPath: path)
            ? try? String(contentsOfFile: path, encoding: .utf8)
            : nil
        // A binary file reads as nil even though it exists; storing that would turn a revert into
        // a delete. Record it as untouched rather than risk destroying it.
        if fileManager.fileExists(atPath: path), existing == nil { return }
        windows[k, default: Window()].entries[path] = Entry(previousContents: existing, firstTouched: Date())
    }

    // MARK: - Reporting

    /// What the current turn has changed, compared against what was recorded.
    public func summary(session: String? = nil, fileManager: FileManager = .default) -> Summary {
        var created: [String] = []
        var modified: [String] = []
        var deleted: [String] = []

        for (path, entry) in entries(session) {
            let existsNow = fileManager.fileExists(atPath: path)
            switch (entry.previousContents, existsNow) {
            case (nil, true):
                created.append(path)
            case (nil, false):
                continue // created then removed again — nothing to show
            case (_, false):
                deleted.append(path)
            case (let before?, true):
                let now = try? String(contentsOfFile: path, encoding: .utf8)
                if now != before { modified.append(path) }
            }
        }
        return Summary(
            created: created.sorted(),
            modified: modified.sorted(),
            deleted: deleted.sorted()
        )
    }

    public func trackedPaths(session: String? = nil) -> [String] { entries(session).keys.sorted() }

    /// The turn's baseline, for `SessionCheckpointStore` to seal into durable history.
    ///
    /// This window still gets discarded on the next `beginTurn`. What survives is the copy on
    /// disk, which only the user can reach — the agent's own `revert_changes` stays scoped to the
    /// turn it is running in.
    public func baseline(session: String? = nil) -> [FileBaseline] {
        entries(session).map { path, entry in
            FileBaseline(
                path: path,
                previousContents: entry.previousContents,
                existedBefore: entry.previousContents != nil
            )
        }
        .sorted { $0.path < $1.path }
    }

    /// One changed file, with both sides, so a reviewer can be shown a diff rather than a list.
    public struct Change: Sendable, Identifiable, Equatable {
        public enum Kind: String, Sendable { case created, modified, deleted }
        public var id: String { path }
        public var path: String
        /// nil when the turn created the file.
        public var before: String?
        /// nil when the turn deleted the file.
        public var after: String?
        public var kind: Kind
    }

    /// Everything the turn changed, newest state included, ready to render.
    public func changes(session: String? = nil, fileManager: FileManager = .default) -> [Change] {
        var out: [Change] = []
        for (path, entry) in entries(session) {
            let existsNow = fileManager.fileExists(atPath: path)
            let now = existsNow ? try? String(contentsOfFile: path, encoding: .utf8) : nil
            switch (entry.previousContents, existsNow) {
            case (nil, true):
                out.append(Change(path: path, before: nil, after: now, kind: .created))
            case (let before?, false):
                out.append(Change(path: path, before: before, after: nil, kind: .deleted))
            case (let before?, true) where now != before:
                out.append(Change(path: path, before: before, after: now, kind: .modified))
            default:
                continue
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Revert a single file and stop tracking it, leaving the rest of the turn intact.
    @discardableResult
    public func revert(path: String, session: String? = nil, fileManager: FileManager = .default) -> Bool {
        let k = key(session)
        guard let entry = windows[k]?.entries[path] else { return false }
        defer { windows[k]?.entries.removeValue(forKey: path) }
        if let previous = entry.previousContents {
            return (try? previous.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        }
        guard fileManager.fileExists(atPath: path) else { return true }
        return (try? fileManager.removeItem(atPath: path)) != nil
    }

    // MARK: - Reverting

    /// Write `contents` to a tracked file, but only if it still holds `expectedCurrent`.
    ///
    /// A hunk revert is computed from the text the reviewer is looking at. If the agent, an editor
    /// or a formatter has changed the file since, writing that result would silently undo their
    /// change, so a mismatch refuses and the caller reloads. The checkpoint is kept: the file still
    /// differs from where the turn began, and the rest of the review still works.
    @discardableResult
    public func applyPartialRevert(path: String, expectedCurrent: String, contents: String, session: String? = nil) -> Bool {
        guard entries(session)[path] != nil,
              let current = try? String(contentsOfFile: path, encoding: .utf8),
              current == expectedCurrent else { return false }
        return (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Put every recorded file back as it was when the turn began.
    @discardableResult
    public func revertTurn(session: String? = nil, fileManager: FileManager = .default) -> RevertOutcome {
        var restored: [String] = []
        var removed: [String] = []
        var failed: [String] = []

        let k = key(session)
        for (path, entry) in windows[k]?.entries ?? [:] {
            if let previous = entry.previousContents {
                do {
                    try previous.write(toFile: path, atomically: true, encoding: .utf8)
                    restored.append(path)
                } catch {
                    failed.append(path)
                }
            } else if fileManager.fileExists(atPath: path) {
                do {
                    try fileManager.removeItem(atPath: path)
                    removed.append(path)
                } catch {
                    failed.append(path)
                }
            }
        }
        windows[k]?.entries.removeAll()
        return RevertOutcome(
            restored: restored.sorted(),
            removed: removed.sorted(),
            failed: failed.sorted()
        )
    }

    // MARK: - Rendering

    public nonisolated static func describe(_ summary: Summary, root: String = "") -> String {
        guard !summary.isEmpty else { return "No file changes recorded this turn." }
        func relative(_ path: String) -> String {
            guard !root.isEmpty else { return path }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        var lines: [String] = []
        for path in summary.created { lines.append("  added     \(relative(path))") }
        for path in summary.modified { lines.append("  modified  \(relative(path))") }
        for path in summary.deleted { lines.append("  deleted   \(relative(path))") }
        return "\(summary.totalCount) file(s) changed this turn:\n" + lines.joined(separator: "\n")
    }

    public nonisolated static func describe(_ outcome: RevertOutcome, root: String = "") -> String {
        if outcome.restored.isEmpty && outcome.removed.isEmpty && outcome.failed.isEmpty {
            return "Nothing to revert — no file changes were recorded this turn."
        }
        func relative(_ path: String) -> String {
            guard !root.isEmpty else { return path }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        var lines: [String] = []
        if !outcome.restored.isEmpty {
            lines.append("Restored \(outcome.restored.count): " + outcome.restored.map(relative).joined(separator: ", "))
        }
        if !outcome.removed.isEmpty {
            lines.append("Removed \(outcome.removed.count) file(s) the turn created: " + outcome.removed.map(relative).joined(separator: ", "))
        }
        if !outcome.failed.isEmpty {
            lines.append("Could NOT revert \(outcome.failed.count): " + outcome.failed.map(relative).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
