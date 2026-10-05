import Foundation
import SwiftOpenWorkCore

/// Chat history as one file per session, under `sessions/`, plus `_order.json` for their order.
///
/// It was one `sessions.json` holding every session, rewritten whole about once a second while a
/// reply streamed, so the cost of each write grew with all the history there is. Now only the
/// sessions that changed are written. And one damaged session no longer takes the rest with it:
/// a file that will not decode is set aside (`….corrupt-<time>`) and the others load.
final class SessionStore: @unchecked Sendable {
    static let folder = "sessions"
    static let orderFile = "_order.json"

    private let lock = NSLock()
    /// What is on disk for each session, to skip writing one that has not changed. Comparing
    /// sessions that share storage with the cached copy is cheap; only changed ones differ.
    private var written: [String: Session] = [:]
    private var writtenOrder: [String]?

    private func directory(_ storage: StorageService) -> URL {
        storage.fileURL(for: Self.folder)
    }

    static func fileName(for id: String) -> String {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return "\(Self.folder)/\(safe).json"
    }

    func exists(storage: StorageService) -> Bool {
        FileManager.default.fileExists(atPath: directory(storage).appendingPathComponent(Self.orderFile).path)
    }

    func write(_ sessions: [Session], storage: StorageService) {
        lock.lock(); defer { lock.unlock() }
        let dir = directory(storage)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var keep = Set<String>()
        for session in sessions {
            let name = Self.fileName(for: session.id)
            keep.insert((name as NSString).lastPathComponent)
            if written[session.id] != session {
                storage.save(session, to: name)
                written[session.id] = session
            }
        }
        let order = sessions.map(\.id)
        if writtenOrder != order {
            storage.save(order, to: "\(Self.folder)/\(Self.orderFile)")
            writtenOrder = order
        }
        keep.insert(Self.orderFile)
        let present = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in present where file.hasSuffix(".json") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
        let ids = Set(sessions.map(\.id))
        written = written.filter { ids.contains($0.key) }
    }

    /// Every session that can be read, in saved order. nil when the folder does not exist yet.
    func read(storage: StorageService) -> [Session]? {
        lock.lock(); defer { lock.unlock() }
        guard exists(storage: storage) else { return nil }
        let dir = directory(storage)
        let order = storage.load([String].self, from: "\(Self.folder)/\(Self.orderFile)") ?? []
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != Self.orderFile }
        var byFile: [String: Session] = [:]
        for file in files {
            if let session = storage.load(Session.self, from: "\(Self.folder)/\(file)") {
                byFile[file] = session
            } else {
                Self.setAside(dir.appendingPathComponent(file))
            }
        }
        var result: [Session] = []
        var used = Set<String>()
        for id in order {
            let file = (Self.fileName(for: id) as NSString).lastPathComponent
            if let session = byFile[file], used.insert(file).inserted { result.append(session) }
        }
        // Files the order does not mention (written, then the app quit before the order was).
        for (file, session) in byFile.sorted(by: { $0.value.updatedAt > $1.value.updatedAt }) where used.insert(file).inserted {
            result.append(session)
        }
        written = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        writtenOrder = result.map(\.id)
        return result
    }

    /// Rename a file that could not be read so nothing overwrites it, keeping it for recovery.
    static func setAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
