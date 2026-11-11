import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// The rule this codebase kept breaking: **nothing ships with a control until something reads it.**
///
/// Two sweeps of `AppSettings` found roughly twenty switches that changed a value in
/// settings.json and nothing else — a GPU budget slider rendering a number in green that no code
/// enforced, voice toggles over buttons drawn unconditionally, a compaction threshold with no UI
/// at all. Each was small; the pattern was the product's biggest credibility problem.
///
/// A sweep is a thing you do once and then stop doing, so this is the sweep as a test. It reads
/// the sources rather than the model, because a field is only alive if some *other* file
/// mentions it.
final class NoDeadSettingsTests: XCTestCase {

    /// Fields with no reader, each for a stated reason. Adding to this list should feel bad.
    private static let knownDead: Set<String> = [
        // Vestigial by design: the toggle reads SMAppService directly, because macOS is the only
        // authority on whether a login item is registered.
        "startOnLogin",
        // Internal bookkeeping, deliberately not user-facing.
        "settingsSchemaVersion"
    ]

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SwiftOpenWorkTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
    }

    /// Every stored field name, read from the model's own declaration.
    private func declaredFields() throws -> [String] {
        let settingsFile = SourceTree.url("Models/Settings.swift")
        let source = try String(contentsOf: settingsFile, encoding: .utf8)
        guard let start = source.range(of: "public struct AppSettings"),
              let end = source.range(of: "public static let currentSchemaVersion") else {
            return []
        }
        let body = source[start.lowerBound..<end.lowerBound]
        return body
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("public var ") else { return nil }
                return trimmed
                    .dropFirst("public var ".count)
                    .prefix { $0.isLetter || $0.isNumber }
                    .description
            }
    }

    private func swiftFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testEverySettingHasSomethingThatReadsIt() throws {
        let fields = try declaredFields()
        XCTAssertGreaterThan(fields.count, 40, "the field sweep found almost nothing — did the parser break?")

        var sources: [(path: String, text: String)] = []
        for file in try swiftFiles() {
            // A field's own declaration file cannot count as a reader of it.
            guard !file.path.hasSuffix("Models/Settings.swift") else { continue }
            sources.append((file.path, try String(contentsOf: file, encoding: .utf8)))
        }

        var dead: [String] = []
        for field in fields where !Self.knownDead.contains(field) {
            let referenced = sources.contains { source in
                source.text.contains(".\(field)")
            }
            if !referenced { dead.append(field) }
        }

        XCTAssertTrue(dead.isEmpty, """
        These settings have a control and no reader — a switch that reads as a guarantee and \
        delivers nothing: \(dead.sorted().joined(separator: ", ")).
        Wire them, or add them to `knownDead` with a reason for why the UI is honest about it.
        """)
    }

    /// The other half: a field nothing exposes is unreachable configuration.
    func testEverySettingIsReachableFromTheUI() throws {
        let fields = try declaredFields()
        let settingsView = try SourceTree.settingsViewSource()
        let notUserFacing: Set<String> = [
            // Set implicitly by switching workspace, not by a control.
            "defaultWorkspaceId",
            // Internal bookkeeping.
            "settingsSchemaVersion"
        ]

        var unreachable: [String] = []
        for field in fields where !notUserFacing.contains(field) {
            if !settingsView.contains("settings.\(field)") { unreachable.append(field) }
        }

        XCTAssertTrue(unreachable.isEmpty, """
        These settings are read by the engine but have no control anywhere, so the only way to \
        change them is to hand-edit settings.json: \(unreachable.sorted().joined(separator: ", ")).
        """)
    }
}
