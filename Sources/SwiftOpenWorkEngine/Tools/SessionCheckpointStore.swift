import Foundation
import CryptoKit
import SwiftOpenWorkStorage

/// One file as it stood before a turn first touched it.
public struct FileBaseline: Sendable, Equatable {
    public var path: String
    /// The contents before the turn. nil when the file did not exist, or could not be read.
    public var previousContents: String?
    /// False when the turn created the file, so restoring means deleting it.
    public var existedBefore: Bool

    public init(path: String, previousContents: String?, existedBefore: Bool) {
        self.path = path
        self.previousContents = previousContents
        self.existedBefore = existedBefore
    }
}

/// Durable, user-driven rewind of agent file edits.
///
/// `FileCheckpointStore` keeps only the current turn on purpose: an *agent* that can silently undo
/// ten turns of your work is worse than one that cannot undo at all. That argument is about the
/// agent. A person who opens their own transcript, picks a point, and is shown the exact list of
/// files that will change is doing something else entirely — and they need the history to still
/// exist, including after a relaunch, which is when "I'll sort this out later" actually happens.
///
/// So each finished turn seals one checkpoint here: the prior contents of every file that turn
/// touched. Contents are content-addressed, so a file edited in twenty turns costs twenty digests
/// rather than twenty copies. Restoring to a checkpoint replays the *oldest* recorded state of
/// each path from that checkpoint forward, which reconstructs the tree as it stood before the turn
/// ran — not merely the last edit undone.
public actor SessionCheckpointStore {
    public static let shared = SessionCheckpointStore()

    /// Beyond this a snapshot costs more than the undo is worth, so the path is recorded as
    /// touched-but-unrecoverable rather than silently dropped. Restore reports it either way.
    public static let maxBlobBytes = 2 * 1024 * 1024

    /// Old checkpoints are pruned oldest-first. Forty turns of history is far past the point where
    /// anyone reaches back, and it bounds the blob directory without needing a byte budget.
    public static let maxCheckpointsPerSession = 40

    public struct FileSnapshot: Codable, Sendable, Equatable {
        public var path: String
        /// Digest of the pre-turn contents, or nil when there are none to restore.
        public var blob: String?
        public var existedBefore: Bool

        /// The file was there but could not be snapshotted (binary, unreadable, or too large).
        public var isUnrecoverable: Bool { existedBefore && blob == nil }
    }

    public struct Checkpoint: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// Monotonic within a session. Ordering by date would be ambiguous for same-second turns.
        public var sequence: Int
        /// The user message that opened the turn, so the transcript can offer a restore point.
        public var messageId: String?
        public var label: String
        public var createdAt: Date
        public var files: [FileSnapshot]

        public var fileCount: Int { files.count }
    }

    /// What a restore would do, so it can be shown before anything is written.
    public struct RestorePlan: Sendable, Equatable {
        public var restore: [String]
        public var delete: [String]
        public var unrecoverable: [String]
        public var turnsUndone: Int

        public var isEmpty: Bool { restore.isEmpty && delete.isEmpty && unrecoverable.isEmpty }
        public var affectedCount: Int { restore.count + delete.count }
    }

    public struct RestoreOutcome: Sendable, Equatable {
        public var restored: [String]
        public var deleted: [String]
        public var failed: [String]
        public var unrecoverable: [String]
        public var turnsUndone: Int
    }

    private let root: URL
    private let fileManager: FileManager

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        self.root = root ?? StorageService.shared.baseDirectory
            .appendingPathComponent("Checkpoints", isDirectory: true)
        self.fileManager = fileManager
    }

    // MARK: - Recording

    /// Seal the turn's baseline as a checkpoint. Does nothing when the turn touched no files.
    @discardableResult
    public func record(
        sessionId: String,
        messageId: String?,
        label: String,
        baselines: [FileBaseline]
    ) -> Checkpoint? {
        guard !sessionId.isEmpty, !baselines.isEmpty else { return nil }

        var snapshots: [FileSnapshot] = []
        for baseline in baselines.sorted(by: { $0.path < $1.path }) {
            guard baseline.existedBefore else {
                snapshots.append(FileSnapshot(path: baseline.path, blob: nil, existedBefore: false))
                continue
            }
            let blob = baseline.previousContents.flatMap { writeBlob($0, sessionId: sessionId) }
            snapshots.append(FileSnapshot(path: baseline.path, blob: blob, existedBefore: true))
        }

        var manifest = loadManifest(sessionId: sessionId)
        let checkpoint = Checkpoint(
            id: UUID().uuidString,
            sequence: (manifest.last?.sequence ?? 0) + 1,
            messageId: messageId,
            label: label,
            createdAt: Date(),
            files: snapshots
        )
        manifest.append(checkpoint)

        if manifest.count > Self.maxCheckpointsPerSession {
            manifest.removeFirst(manifest.count - Self.maxCheckpointsPerSession)
        }
        saveManifest(manifest, sessionId: sessionId)
        collectGarbage(sessionId: sessionId, manifest: manifest)
        return checkpoint
    }

    // MARK: - Reading

    public func checkpoints(forSession sessionId: String) -> [Checkpoint] {
        loadManifest(sessionId: sessionId)
    }

    /// The checkpoint opened by a given message, if that turn changed anything.
    public func checkpoint(forSession sessionId: String, messageId: String) -> Checkpoint? {
        loadManifest(sessionId: sessionId).first { $0.messageId == messageId }
    }

    /// Message ids that can be restored to, for decorating a transcript without a call per row.
    public func restorableMessageIds(forSession sessionId: String) -> Set<String> {
        Set(loadManifest(sessionId: sessionId).compactMap(\.messageId))
    }

    // MARK: - Restoring

    public func plan(sessionId: String, checkpointId: String) -> RestorePlan {
        let undone = checkpointsToUndo(sessionId: sessionId, checkpointId: checkpointId)
        guard !undone.isEmpty else {
            return RestorePlan(restore: [], delete: [], unrecoverable: [], turnsUndone: 0)
        }
        var restore: [String] = []
        var delete: [String] = []
        var unrecoverable: [String] = []
        for snapshot in earliestSnapshots(in: undone) {
            if snapshot.isUnrecoverable {
                unrecoverable.append(snapshot.path)
            } else if snapshot.existedBefore {
                restore.append(snapshot.path)
            } else {
                delete.append(snapshot.path)
            }
        }
        return RestorePlan(
            restore: restore.sorted(),
            delete: delete.sorted(),
            unrecoverable: unrecoverable.sorted(),
            turnsUndone: undone.count
        )
    }

    /// Put the tree back as it stood before `checkpointId`'s turn ran.
    ///
    /// Undone checkpoints are dropped afterwards: leaving them would offer a second restore to a
    /// state that no longer has a baseline on either side of it.
    @discardableResult
    public func restore(sessionId: String, checkpointId: String) -> RestoreOutcome {
        let undone = checkpointsToUndo(sessionId: sessionId, checkpointId: checkpointId)
        guard !undone.isEmpty else {
            return RestoreOutcome(restored: [], deleted: [], failed: [], unrecoverable: [], turnsUndone: 0)
        }

        var restored: [String] = []
        var deleted: [String] = []
        var failed: [String] = []
        var unrecoverable: [String] = []

        for snapshot in earliestSnapshots(in: undone) {
            if snapshot.isUnrecoverable {
                unrecoverable.append(snapshot.path)
                continue
            }
            guard snapshot.existedBefore else {
                if fileManager.fileExists(atPath: snapshot.path) {
                    if (try? fileManager.removeItem(atPath: snapshot.path)) != nil {
                        deleted.append(snapshot.path)
                    } else {
                        failed.append(snapshot.path)
                    }
                } else {
                    deleted.append(snapshot.path)
                }
                continue
            }
            guard let blob = snapshot.blob, let contents = readBlob(blob, sessionId: sessionId) else {
                unrecoverable.append(snapshot.path)
                continue
            }
            do {
                // The turn may have removed the directory along with the file.
                let parent = (snapshot.path as NSString).deletingLastPathComponent
                if !parent.isEmpty, !fileManager.fileExists(atPath: parent) {
                    try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                }
                try contents.write(toFile: snapshot.path, atomically: true, encoding: .utf8)
                restored.append(snapshot.path)
            } catch {
                failed.append(snapshot.path)
            }
        }

        let undoneIds = Set(undone.map(\.id))
        let remaining = loadManifest(sessionId: sessionId).filter { !undoneIds.contains($0.id) }
        saveManifest(remaining, sessionId: sessionId)
        collectGarbage(sessionId: sessionId, manifest: remaining)

        return RestoreOutcome(
            restored: restored.sorted(),
            deleted: deleted.sorted(),
            failed: failed.sorted(),
            unrecoverable: unrecoverable.sorted(),
            turnsUndone: undone.count
        )
    }

    /// Drop a session's whole history. Called when the session itself is deleted.
    public func deleteAll(forSession sessionId: String) {
        try? fileManager.removeItem(at: sessionDirectory(sessionId))
    }

    /// Seal whatever the finished turn recorded in `FileCheckpointStore`.
    ///
    /// Every path that runs a turn calls this, including the headless ones — an automation that
    /// rewrote six files at 3am is exactly the run you want to be able to undo.
    public static func sealCurrentTurn(sessionId: String, messageId: String?, label: String) async {
        let baseline = await FileCheckpointStore.shared.baseline(session: sessionId)
        guard !baseline.isEmpty else { return }
        await shared.record(
            sessionId: sessionId,
            messageId: messageId,
            label: String(label.prefix(80)),
            baselines: baseline
        )
    }

    // MARK: - Selection

    /// The target checkpoint and every later one, oldest first.
    private func checkpointsToUndo(sessionId: String, checkpointId: String) -> [Checkpoint] {
        let manifest = loadManifest(sessionId: sessionId)
        guard let target = manifest.first(where: { $0.id == checkpointId }) else { return [] }
        return manifest.filter { $0.sequence >= target.sequence }.sorted { $0.sequence < $1.sequence }
    }

    /// One snapshot per path: the oldest, which is the state before any of these turns ran.
    private func earliestSnapshots(in checkpoints: [Checkpoint]) -> [FileSnapshot] {
        var byPath: [String: FileSnapshot] = [:]
        for checkpoint in checkpoints.sorted(by: { $0.sequence < $1.sequence }) {
            for snapshot in checkpoint.files where byPath[snapshot.path] == nil {
                byPath[snapshot.path] = snapshot
            }
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    // MARK: - Storage

    private func sessionDirectory(_ sessionId: String) -> URL {
        // Session ids are UUIDs, but a manifest path is not the place to trust that.
        let safe = sessionId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        return root.appendingPathComponent(safe, isDirectory: true)
    }

    private func blobDirectory(_ sessionId: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent("blobs", isDirectory: true)
    }

    private func manifestURL(_ sessionId: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent("manifest.json")
    }

    private func loadManifest(sessionId: String) -> [Checkpoint] {
        guard let data = try? Data(contentsOf: manifestURL(sessionId)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = (try? decoder.decode([Checkpoint].self, from: data)) ?? []
        return manifest.sorted { $0.sequence < $1.sequence }
    }

    private func saveManifest(_ manifest: [Checkpoint], sessionId: String) {
        let directory = sessionDirectory(sessionId)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        let url = manifestURL(sessionId)
        try? data.write(to: url, options: .atomic)
        // Snapshots are verbatim source, same as the transcripts next to them.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Store contents under their digest and return it, or nil when they are too big to keep.
    private func writeBlob(_ contents: String, sessionId: String) -> String? {
        let data = Data(contents.utf8)
        guard data.count <= Self.maxBlobBytes else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = blobDirectory(sessionId)
        let url = directory.appendingPathComponent(digest)
        guard !fileManager.fileExists(atPath: url.path) else { return digest }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return digest
    }

    private func readBlob(_ digest: String, sessionId: String) -> String? {
        let url = blobDirectory(sessionId).appendingPathComponent(digest)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drop blobs no surviving checkpoint refers to, after a prune or a restore.
    private func collectGarbage(sessionId: String, manifest: [Checkpoint]) {
        let live = Set(manifest.flatMap { $0.files.compactMap(\.blob) })
        let directory = blobDirectory(sessionId)
        let existing = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where !live.contains(name) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
