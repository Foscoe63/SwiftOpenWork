import Foundation
@testable import SwiftOpenWorkEngine

/// The app's own source files, for the tests that read them.
///
/// Files are found by name rather than by path, because the modules under `Sources/` are still
/// being split out and a file's folder changes when it moves to another module. Every file name
/// under `Sources/` is unique; `url(_:)` stops the test if that ever changes.
///
/// Both test targets carry an identical copy of this file; change them together.
enum SourceTree {
    /// `Sources/` at the repository root.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // the test target's folder
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources")

    /// Every Swift file under `Sources/`.
    static var swiftFiles: [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The file a path such as `Engine/Agents/AgentRunner.swift` names. Only its file name is used.
    static func url(_ path: String) -> URL {
        let name = (path as NSString).lastPathComponent
        let matches = swiftFiles.filter { $0.lastPathComponent == name }
        precondition(matches.count == 1, "expected exactly one \(name) under Sources/, found \(matches.count)")
        return matches[0]
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    /// Several files as one text, for a check on code that is spread over more than one file.
    static func read(_ paths: [String]) throws -> String {
        try paths.map(read).joined(separator: "\n")
    }

    /// The tool engine with its built-in tools: `ToolExecutionEngine.swift`, the registry, and
    /// every handler file under `Tools/Handlers/`.
    static func toolEngineSource() throws -> String {
        let handlers = swiftFiles
            .filter { $0.deletingLastPathComponent().lastPathComponent == "Handlers" }
            .map(\.lastPathComponent)
            .sorted()
        return try read(["ToolExecutionEngine.swift", "ToolHandlerRegistry.swift"] + handlers)
    }

    /// The agent loop: `AgentRunner.swift` and the turn it runs, `AgentTurn.swift`.
    static func agentLoopSource() throws -> String {
        try read(["AgentRunner.swift", "AgentTurn.swift"])
    }

    /// The Settings window: `SettingsView.swift` and the `SettingsView+<Section>.swift` files its
    /// pages live in.
    static func settingsViewSource() throws -> String {
        let sections = swiftFiles.map(\.lastPathComponent).filter { $0.hasPrefix("SettingsView+") }.sorted()
        return try read(["SettingsView.swift"] + sections)
    }
}
