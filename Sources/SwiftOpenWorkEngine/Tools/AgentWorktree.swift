import Foundation
import SwiftOpenWorkCore

/// Isolated git worktrees for agent work, and a commit that can only land inside one.
///
/// Git was read-only here on purpose — "committing stays yours" — and that is the right instinct
/// applied in the wrong place. The cost was that an agent had no way to checkpoint across turns,
/// and `FileCheckpointStore` is deliberately turn-scoped, so anything older than the current turn
/// was unrecoverable. Session-wide undo was rejected for a good reason: an agent that can
/// silently revert ten turns of your work is worse than one that cannot revert at all.
///
/// A worktree resolves that rather than trading it off. On a branch of its own, in a directory of
/// its own, commits are additive history rather than a rewrite: nothing the agent does can revert
/// or reword anything you wrote, because it is not writing where you are. `commit` refuses to run
/// anywhere else, which is what keeps the original promise intact.
public enum AgentWorktree {

    public struct Info: Sendable, Equatable {
        public var path: String
        public var branch: String
        public var head: String
    }

    public enum WorktreeError: LocalizedError {
        case notARepository(String)
        case gitFailed(String)
        case notAWorktree(String)
        case nothingToCommit

        public var errorDescription: String? {
            switch self {
            case .notARepository(let path):
                return "\(path) is not inside a git repository, so there is nothing to branch from."
            case .gitFailed(let message):
                return message
            case .notAWorktree(let path):
                return """
                \(path) is not an agent worktree, so committing there is refused.
                Commits are confined to worktrees created by worktree_create: on your own checkout, \
                committing stays yours. Create one first, or commit this yourself.
                """
            case .nothingToCommit:
                return "Nothing staged or changed in the worktree — no commit made."
            }
        }
    }

    /// Where agent worktrees live: beside the repo, never inside it, so they are never picked up
    /// by the parent's own status, build, or file search.
    public static func container(for repoRoot: URL) -> URL {
        repoRoot.deletingLastPathComponent()
            .appendingPathComponent("\(AppIdentity.worktreeContainerName)/\(repoRoot.lastPathComponent)", isDirectory: true)
    }

    /// Where 1.1, before the rename, put them. Still listed, removable and committable.
    public static func legacyContainer(for repoRoot: URL) -> URL {
        repoRoot.deletingLastPathComponent()
            .appendingPathComponent("\(AppIdentity.legacyWorktreeContainerName)/\(repoRoot.lastPathComponent)", isDirectory: true)
    }

    /// Branches this app created, under either name.
    public static func isAgentBranch(_ branch: String) -> Bool {
        branch.hasPrefix(AppIdentity.worktreeBranchPrefix) || branch.hasPrefix(AppIdentity.legacyWorktreeBranchPrefix)
    }

    /// Serial queue every git subprocess runs on.
    ///
    /// `Process.waitUntilExit()` spins the run loop when called on the main thread, so a git call
    /// from a `@MainActor` context both freezes the UI for the length of the command and lets
    /// unrelated main-thread work re-enter in the middle of it. Keeping the wait on this queue
    /// means callers suspend instead of blocking. Serial, because parallel sub-agents otherwise
    /// race each other for the repository's `index.lock`.
    private static let gitQueue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".agent-worktree.git")

    /// Exposed so a test can assert the queue is not the main thread.
    public static var gitQueueForTesting: DispatchQueue { gitQueue }

    @discardableResult
    public static func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            gitQueue.async {
                continuation.resume(with: Result { try gitSync(arguments, in: directory) })
            }
        }
    }

    /// The blocking implementation. Only ever reached from `gitQueue`, never the main thread.
    @discardableResult
    public static func gitSync(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw WorktreeError.gitFailed("git \(arguments.joined(separator: " ")) failed:\n\(output)")
        }
        return output
    }

    public static func repositoryRoot(containing path: String) async throws -> URL {
        let directory = URL(fileURLWithPath: path)
        do {
            let out = try await git(["rev-parse", "--show-toplevel"], in: directory)
            return URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw WorktreeError.notARepository(path)
        }
    }

    /// Create a worktree on a new branch. Returns the worktree directory.
    public static func create(workspacePath: String, name: String) async throws -> Info {
        let root = try await repositoryRoot(containing: workspacePath)
        let slug = sanitize(name)
        let branch = AppIdentity.worktreeBranchPrefix + slug
        let dir = container(for: root).appendingPathComponent(slug, isDirectory: true)

        try FileManager.default.createDirectory(
            at: dir.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: dir.path) {
            // Reuse rather than fail: re-running the same task should land in the same place.
            let head = (try? await git(["rev-parse", "--short", "HEAD"], in: dir)) ?? ""
            return Info(path: dir.path, branch: branch, head: head.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // `-B` so an abandoned branch from a previous run is reset rather than colliding.
        try await git(["worktree", "add", "-B", branch, dir.path], in: root)
        let head = try await git(["rev-parse", "--short", "HEAD"], in: dir)
        return Info(path: dir.path, branch: branch, head: head.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What `seedWithUncommittedChanges` did.
    public struct Seed: Sendable, Equatable {
        /// The commit the worktree now starts from: a snapshot of the parent's uncommitted state,
        /// or the unchanged HEAD when there was nothing to copy.
        public var head: String
        public var copiedChanges: Bool
        /// Set when the parent's state could not be reproduced, saying what is missing.
        public var problem: String?
    }

    /// Bring the parent checkout's uncommitted work into a fresh worktree, as one commit.
    ///
    /// `git worktree add` starts from the last commit, so a sub-agent working for someone with
    /// uncommitted changes edited the files as they were *before* those changes. A real run had 56
    /// modified files in the parent — the very files it was asked to change among them — and the
    /// sub-agent's edits were against versions the user no longer had, unmergeable by construction.
    /// Tracked changes are applied as a patch and untracked files copied, then committed so
    /// `git status` in the worktree shows only what the sub-agent itself changed.
    public static func seedWithUncommittedChanges(
        worktree: Info,
        workspacePath: String,
        maxUntrackedFiles: Int = 2_000,
        maxUntrackedBytes: Int = 50_000_000
    ) async -> Seed {
        let unchanged = Seed(head: worktree.head, copiedChanges: false, problem: nil)
        guard let root = try? await repositoryRoot(containing: workspacePath) else { return unchanged }
        let target = URL(fileURLWithPath: worktree.path)
        var problems: [String] = []
        var copied = false

        // `git diff --quiet` exits non-zero when there are changes. Checked separately because
        // `git` decodes output as UTF-8 and returns "" for anything else, which would otherwise
        // read as "nothing to copy" and leave the worktree silently stale.
        let hasTrackedChanges = (try? await git(["diff", "HEAD", "--quiet", "--ignore-submodules"], in: root)) == nil
        let patch = (try? await git(["diff", "HEAD", "--binary", "--ignore-submodules"], in: root)) ?? ""
        if hasTrackedChanges && patch.isEmpty {
            problems.append("your uncommitted edits to tracked files could not be read as a patch")
        }
        if !patch.isEmpty {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-seed-\(UUID().uuidString).patch")
            do {
                try patch.write(to: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: file) }
                try await git(["apply", "--whitespace=nowarn", file.path], in: target)
                copied = true
            } catch {
                problems.append("your uncommitted edits to tracked files could not be applied")
            }
        }

        if let listing = try? await git(["ls-files", "--others", "--exclude-standard", "-z"], in: root) {
            let paths = listing.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
            var bytes = 0
            var skipped = 0
            for (index, relative) in paths.enumerated() {
                let source = root.appendingPathComponent(relative)
                let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
                guard index < maxUntrackedFiles, bytes + size <= maxUntrackedBytes else {
                    skipped += 1
                    continue
                }
                let destination = target.appendingPathComponent(relative)
                try? FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                    bytes += size
                    copied = true
                }
            }
            if skipped > 0 {
                problems.append("\(skipped) untracked file(s) were too many or too large to copy")
            }
        }

        guard copied else {
            return Seed(head: worktree.head, copiedChanges: false, problem: problems.first)
        }
        do {
            try await git(["add", "-A"], in: target)
            try await git([
                "-c", "user.name=\(AppIdentity.displayName)", "-c", "user.email=agent@localhost",
                "commit", "-q", "--no-verify", "-m", snapshotSubject,
            ], in: target)
            let head = try await git(["rev-parse", "--short", "HEAD"], in: target)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Seed(head: head, copiedChanges: true, problem: problems.isEmpty ? nil : problems.joined(separator: "; "))
        } catch {
            return Seed(head: worktree.head, copiedChanges: true,
                        problem: "the copied changes could not be committed, so they will show as the sub-agent's own")
        }
    }

    public static func list(workspacePath: String) async throws -> [Info] {
        let root = try await repositoryRoot(containing: workspacePath)
        let output = try await git(["worktree", "list", "--porcelain"], in: root)
        var result: [Info] = []
        var path = "", branch = "", head = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)).prefix(7).description }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if line.isEmpty, !path.isEmpty {
                if isAgentBranch(branch) { result.append(Info(path: path, branch: branch, head: head)) }
                path = ""; branch = ""; head = ""
            }
        }
        if !path.isEmpty, isAgentBranch(branch) {
            result.append(Info(path: path, branch: branch, head: head))
        }
        return result
    }

    public static func remove(workspacePath: String, name: String, force: Bool) async throws -> String {
        let root = try await repositoryRoot(containing: workspacePath)
        let slug = sanitize(name)
        let current = container(for: root).appendingPathComponent(slug, isDirectory: true)
        let legacy = legacyContainer(for: root).appendingPathComponent(slug, isDirectory: true)
        guard let dir = [current, legacy].first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return "No worktree named '\(slug)'."
        }
        let branchName = (try? await git(["rev-parse", "--abbrev-ref", "HEAD"], in: dir))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? AppIdentity.worktreeBranchPrefix + slug
        // Refuse to discard uncommitted work unless told twice: the worktree is where the agent's
        // output lives, and removing it is the one irreversible thing here.
        let dirty = try await git(["status", "--porcelain"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        if !dirty.isEmpty && !force {
            throw WorktreeError.gitFailed("""
            '\(slug)' has uncommitted changes:
            \(dirty)
            Commit them, or pass force: true to discard them permanently.
            """)
        }
        try await git(["worktree", "remove", force ? "--force" : "--", dir.path], in: root)
        return "Removed worktree '\(slug)'. Its branch \(branchName) still exists — delete it with git if you do not want it."
    }

    /// Whether `path` is inside a worktree this type created.
    public static func isAgentWorktree(_ path: String) async -> Bool {
        guard let root = try? await repositoryRoot(containing: path) else { return false }
        guard let branch = try? await git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: path)) else {
            return false
        }
        // Both halves must hold: the branch is ours *and* this is not the primary checkout.
        let isOurBranch = isAgentBranch(branch.trimmingCharacters(in: .whitespacesAndNewlines))
        let commonDir = try? await git(["rev-parse", "--git-common-dir"], in: URL(fileURLWithPath: path))
        let isLinkedWorktree = root.path != URL(fileURLWithPath: path).path
            || commonDir
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".git") && $0.contains("/") } ?? false
        return isOurBranch && isLinkedWorktree
    }

    /// Commit everything in an agent worktree. Refuses anywhere else.
    public static func commit(worktreePath: String, message: String) async throws -> String {
        guard await isAgentWorktree(worktreePath) else {
            throw WorktreeError.notAWorktree(worktreePath)
        }
        let dir = URL(fileURLWithPath: worktreePath)
        let dirty = try await git(["status", "--porcelain"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dirty.isEmpty else { throw WorktreeError.nothingToCommit }

        try await git(["add", "-A"], in: dir)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(["commit", "-m", trimmed.isEmpty ? "Agent checkpoint" : trimmed], in: dir)
        let head = try await git(["rev-parse", "--short", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        let stat = try await git(["show", "--stat", "--format=%s", "HEAD"], in: dir)
        return "Committed \(head) on \(try await branchName(in: dir)):\n\(stat)"
    }

    /// Commit everything in a worktree, under the app's name when the user has no git identity
    /// configured. Returns whether a commit was made.
    @discardableResult
    public static func commitAll(in path: String, message: String) async -> Bool {
        let dir = URL(fileURLWithPath: path)
        guard let dirty = try? await git(["status", "--porcelain"], in: dir),
              !dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? await git(["add", "-A"], in: dir)) != nil else { return false }
        let commit = ["commit", "-q", "--no-verify", "-m", message]
        if (try? await git(commit, in: dir)) != nil { return true }
        let named = ["-c", "user.name=\(AppIdentity.displayName)", "-c", "user.email=agent@localhost"] + commit
        return (try? await git(named, in: dir)) != nil
    }

    // MARK: - Bringing a branch back

    /// The subject of the commit `seedWithUncommittedChanges` makes. A merge must leave it out:
    /// it is the user's own pending work, which their checkout already has.
    public static let snapshotSubject = "Snapshot of uncommitted changes in the parent checkout"

    public enum MergeStrategy: String, Sendable {
        /// The branch's own changes, applied to the checkout's files and left uncommitted.
        case apply
        /// A real `git merge --no-ff` commit. Only on a clean checkout.
        case merge
    }

    /// What a merge would bring in, worked out before anything in the checkout is touched.
    public struct MergePlan: Sendable {
        public var worktree: Info
        public var repoRoot: URL
        /// The commit the agent's own work starts after: the fork point, or the snapshot of the
        /// user's pending edits when the worktree was seeded with them.
        public var base: String
        public var forkPoint: String
        /// Repository-relative paths the branch changes.
        public var files: [String]
        public var stat: String
    }

    /// Find an agent worktree by its folder name, its branch, or its path, commit anything left
    /// loose in it, and work out what it would bring in.
    public static func planMerge(workspacePath: String, name: String) async throws -> MergePlan {
        let root = try await repositoryRoot(containing: workspacePath)
        let trees = try await list(workspacePath: workspacePath)
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = sanitize(wanted)
        guard let tree = trees.first(where: {
            $0.path == wanted
                || $0.branch == wanted
                || URL(fileURLWithPath: $0.path).lastPathComponent == slug
                || $0.branch == AppIdentity.worktreeBranchPrefix + slug
        }) else {
            let known = trees.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            throw WorktreeError.gitFailed(
                "No agent worktree named '\(wanted)'."
                    + (known.isEmpty ? " There are none." : " Worktrees: \(known.joined(separator: ", ")).")
            )
        }
        // Work left uncommitted would otherwise be silently left behind.
        await commitAll(in: tree.path, message: "Work left uncommitted in \(URL(fileURLWithPath: tree.path).lastPathComponent)")
        let tip = try await git(["rev-parse", tree.branch], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let forkPoint = try await git(["merge-base", "HEAD", tree.branch], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base = forkPoint
        let first = try await git(["log", "--reverse", "--format=%H%x09%s", "\(forkPoint)..\(tree.branch)"], in: root)
            .split(separator: "\n").first.map(String.init) ?? ""
        let parts = first.split(separator: "\t", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[1] == snapshotSubject { base = parts[0] }
        guard base != tip else {
            throw WorktreeError.gitFailed("\(tree.branch) has no changes of its own to bring in.")
        }
        let files = try await git(["diff", "--name-only", base, tree.branch], in: root)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let stat = try await git(["diff", "--stat=100", base, tree.branch], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var info = tree
        info.head = tip
        return MergePlan(worktree: info, repoRoot: root, base: base, forkPoint: forkPoint, files: files, stat: stat)
    }

    /// Bring a planned branch into the user's checkout.
    ///
    /// `apply` is the default because it keeps committing the user's: the branch's own changes
    /// land as ordinary edits to review, and the snapshot of their pending work is left out, so a
    /// sub-agent seeded with it does not bring it back twice. `merge` makes a merge commit and is
    /// refused on a dirty checkout, or when the branch carries that snapshot.
    public static func merge(_ plan: MergePlan, strategy: MergeStrategy) async throws -> String {
        let root = plan.repoRoot
        let branch = plan.worktree.branch
        switch strategy {
        case .apply:
            let patch = try await git(["diff", "--binary", plan.base, branch], in: root)
            // `git` reads output as UTF-8 and returns "" for anything else.
            guard !patch.isEmpty else {
                throw WorktreeError.gitFailed("\(branch)'s changes could not be read as a patch. Use strategy merge, or bring them in with git.")
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-merge-\(UUID().uuidString).patch")
            try patch.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            if (try? await git(["apply", "--check", "--whitespace=nowarn", file.path], in: root)) != nil {
                try await git(["apply", "--whitespace=nowarn", file.path], in: root)
                return """
                Applied \(branch) to your checkout as uncommitted changes:
                \(plan.stat)
                Nothing was committed. Review with git_diff; the user commits when satisfied.
                """
            }
            // The checkout moved on under the branch. A three-way apply merges what it can and
            // marks the rest, which is better than refusing outright — but it is reported plainly.
            do {
                try await git(["apply", "--3way", "--whitespace=nowarn", file.path], in: root)
            } catch {
                let conflicted = ((try? await git(["diff", "--name-only", "--diff-filter=U"], in: root)) ?? "")
                    .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                guard !conflicted.isEmpty else { throw error }
                return """
                Applied \(branch) with conflicts. These files now hold conflict markers and must be \
                resolved before anything else: \(conflicted.joined(separator: ", ")).
                \(plan.stat)
                Nothing was committed. Tell the user about the conflicts.
                """
            }
            return """
            Applied \(branch) to your checkout with a three-way merge (your files had changed since it \
            branched), as uncommitted changes:
            \(plan.stat)
            Nothing was committed. Review with git_diff; the user commits when satisfied.
            """
        case .merge:
            guard plan.base == plan.forkPoint else {
                throw WorktreeError.gitFailed(
                    "\(branch) starts from a snapshot of uncommitted changes in your checkout, so a merge would bring "
                        + "them in twice. Use strategy apply."
                )
            }
            let dirty = try await git(["status", "--porcelain", "--untracked-files=no"], in: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard dirty.isEmpty else {
                throw WorktreeError.gitFailed("Your checkout has uncommitted changes, so a merge was refused. Use strategy apply, or commit first.")
            }
            do {
                try await git(["merge", "--no-ff", "--no-edit", "-m", "Merge \(branch)", branch], in: root)
            } catch {
                _ = try? await git(["merge", "--abort"], in: root)
                throw WorktreeError.gitFailed("Merging \(branch) conflicted, so it was undone and nothing changed. Use strategy apply.\n\(error.localizedDescription)")
            }
            let head = try await git(["rev-parse", "--short", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
            return "Merged \(branch) into your checkout as \(head):\n\(plan.stat)"
        }
    }

    public static func branchName(in directory: URL) async throws -> String {
        try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A branch- and path-safe slug. Git refuses a lot of characters in ref names, and a tool
    /// argument is whatever the model felt like typing.
    public static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = collapsed.isEmpty ? "task" : collapsed
        return String(trimmed.prefix(48))
    }
}
