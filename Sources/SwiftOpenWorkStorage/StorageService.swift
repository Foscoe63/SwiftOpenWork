import Foundation
import SwiftOpenWorkCore

public final class StorageService: @unchecked Sendable {
    public static let shared = StorageService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public var baseDirectory: URL {
        let directory = Self.resolvedBaseDirectory
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        _ = Self.permissionsTightened
        return directory
    }

    /// Runs `makeOwnerOnly` once per process, on first use of `baseDirectory`.
    ///
    /// A `static let` rather than a flag guarded by `lock`: `save` and `load` hold `lock` while
    /// they call `fileURL(for:)`, which reads `baseDirectory`. Taking the same non-recursive
    /// `NSLock` here deadlocked the first store access in the process — the app hung at launch
    /// and the test suite stopped dead. Swift runs a `static let` initialiser exactly once and
    /// thread-safely, which is all this needed.
    private static let permissionsTightened: Bool = {
        DispatchQueue.global(qos: .utility).async { makeOwnerOnly(resolvedBaseDirectory) }
        return true
    }()

    /// Owner-only, once per launch: the folder and everything in it. `save` has set 0600 on each
    /// file it writes since that was fixed, but files not written since — memories, skills,
    /// watch items — stayed world-readable, and the folder itself was 0755.
    static func makeOwnerOnly(_ directory: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let mode: Int16 = values?.isDirectory == true ? 0o700 : 0o600
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    /// Names a data folder to use instead of Application Support. For a deliberate test run
    /// against real data, point it at `~/Library/Application Support/SwiftOpenWork`.
    public static let dataDirectoryEnvironmentKey = "SWIFTOPENWORK_DATA_DIRECTORY"

    /// Where settings, sessions, agents and automations live.
    ///
    /// Under XCTest this is a folder of its own, one per test process. `xcodebuild test` launches
    /// the real app as the test host, and tests save settings through the shared store; against
    /// Application Support, a test that crashed before restoring left the developer's settings
    /// changed, and anything the app does at launch ran on real data. Resolved once, so every
    /// store in the process agrees for its whole life.
    public static let resolvedBaseDirectory: URL = resolveBaseDirectory(
        environment: ProcessInfo.processInfo.environment,
        hostedByTests: AppIdentity.isHostedByTests,
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!,
        temporaryDirectory: FileManager.default.temporaryDirectory,
        processIdentifier: ProcessInfo.processInfo.processIdentifier
    )

    public static var testDirectoryPrefix: String { "\(AppIdentity.applicationSupportFolderName)-tests-" }

    /// Delete test data folders whose process has exited, so runs do not pile up.
    public static func removeFinishedTestDirectories(
        in temporaryDirectory: URL,
        isRunning: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
        for name in names where name.hasPrefix(testDirectoryPrefix) {
            guard let pid = Int32(name.dropFirst(testDirectoryPrefix.count)), !isRunning(pid) else { continue }
            try? fileManager.removeItem(at: temporaryDirectory.appendingPathComponent(name))
        }
    }

    public static func resolveBaseDirectory(
        environment: [String: String],
        hostedByTests: Bool,
        applicationSupport: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        if let explicit = environment[dataDirectoryEnvironmentKey], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        if hostedByTests {
            removeFinishedTestDirectories(in: temporaryDirectory)
            return temporaryDirectory.appendingPathComponent("\(testDirectoryPrefix)\(processIdentifier)", isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true)
    }

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func fileURL(for filename: String) -> URL {
        baseDirectory.appendingPathComponent(filename)
    }

    public func save<T: Encodable>(_ object: T, to filename: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try encoder.encode(object)
            let url = fileURL(for: filename)
            try data.write(to: url, options: .atomic)
            // Owner-only. These files hold workspace paths, full chat transcripts and — until
            // `saveProviders` was fixed — API keys, and were being written world-readable (644).
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            print("[StorageService] Error saving \(filename): \(error.localizedDescription)")
        }
    }

    public func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(for: filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(type, from: data)
        } catch {
            print("[StorageService] Error loading \(filename): \(error.localizedDescription)")
            return nil
        }
    }

    public func exportBackup() -> URL? {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("SwiftOpenWorkBackup-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let dest = tempDir.appendingPathComponent(file.lastPathComponent)
            try? fileManager.copyItem(at: file, to: dest)
        }
        return tempDir
    }

    public func clearAllData() {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}
