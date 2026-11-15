import Foundation
import SwiftOpenWorkCore

/// The Team map on disk: departments, who sits where, shared instructions and shared notes.
///
/// Two rules, both learned from `StorageService.load`, which returns nil for "no file" and for "file I
/// could not read" alike. A caller that treats nil as empty and saves has just replaced the person's
/// data with nothing:
///
/// - **A file that exists but cannot be read is copied aside before anything can replace it**, under a
///   name that carries the time, and is never touched again. The map then starts empty.
/// - **Every save that would replace a different file first copies that file to `team_map.previous.json`**,
///   so one bad save (a bug, a crash mid-edit) is a step back, not a loss.
public final class TeamMapStore: @unchecked Sendable {
    public static let filename = "team_map.json"
    public static let previousFilename = "team_map.previous.json"

    public enum Loaded: Equatable, Sendable {
        /// No file yet: a fresh install, or nothing was ever saved.
        case missing
        case state(TeamMapState)
        /// The file is there but is not a Team map. It was copied to `copiedTo` (nil if even the copy failed).
        case unreadable(copiedTo: URL?)
    }

    private let directory: @Sendable () -> URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public static let shared = TeamMapStore { StorageService.shared.baseDirectory }

    public init(directory: @escaping @Sendable () -> URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public var fileURL: URL { directory().appendingPathComponent(Self.filename) }
    private var previousURL: URL { directory().appendingPathComponent(Self.previousFilename) }

    public func load() -> Loaded {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// The state to run with: what was saved, or an empty map when there is nothing usable.
    public func loadState() -> TeamMapState {
        switch load() {
        case .state(let state): return state
        case .missing, .unreadable: return TeamMapState()
        }
    }

    private func loadLocked() -> Loaded {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .state(try decoder.decode(TeamMapState.self, from: data))
        } catch {
            return .unreadable(copiedTo: setAsideLocked(url))
        }
    }

    /// Copies a file we could not read next to itself, under a name that is not reused.
    private func setAsideLocked(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var target = url.deletingLastPathComponent().appendingPathComponent("team_map.unreadable-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("team_map.unreadable-\(stamp)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target
        } catch {
            return nil
        }
    }

    /// Writes the map. Refuses (returns false) when the file already there is unreadable and could not be
    /// copied aside: that file is the only copy of someone's data and is left exactly as it is.
    @discardableResult
    public func save(_ state: TeamMapState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        let fm = FileManager.default
        guard let data = try? encoder.encode(state) else { return false }
        if fm.fileExists(atPath: url.path) {
            let existing = try? Data(contentsOf: url)
            if existing == data { return true }
            if let existing, (try? decoder.decode(TeamMapState.self, from: existing)) == nil {
                // It stopped being readable since we loaded it (edited by hand, half-written, newer format).
                guard setAsideLocked(url) != nil else { return false }
            }
            if existing != nil {
                try? fm.removeItem(at: previousURL)
                try? fm.copyItem(at: url, to: previousURL)
            }
        }
        do {
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            print("[TeamMapStore] Error saving \(Self.filename): \(error.localizedDescription)")
            return false
        }
    }
}

extension PersistenceManager {
    public func loadTeamMap() -> TeamMapState { TeamMapStore.shared.loadState() }

    @discardableResult
    public func saveTeamMap(_ state: TeamMapState) -> Bool { TeamMapStore.shared.save(state) }
}
