import XCTest
import SwiftUI
import AppKit
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

/// Renders the real Team map screens, with real data from a real `AppState`, to PNG files. It only
/// runs when /private/tmp/team_shots_dir.txt names an output folder,
/// so an ordinary run is unaffected. These are renders of the views, not a person clicking.
@MainActor
final class TeamMapScreenshotTests: XCTestCase {
    private func shot<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRenderTheTeamMapScreens() throws {
        guard let dir = (try? String(contentsOfFile: "/private/tmp/team_shots_dir.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { throw XCTSkip("/private/tmp/team_shots_dir.txt not present") }
        XCTAssertTrue(StorageService.resolvedBaseDirectory.path.lowercased().contains("test"))
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let app = AppState()
        let soft = app.createDepartment(from: DepartmentTemplateCatalog.softwareTeam, named: "App-Coder")
        let writing = app.createDepartment(from: DepartmentTemplateCatalog.writingTeam, named: "Docs")
        defer { for a in soft + writing { app.deleteAgent(a) }; app.deleteDepartment("App-Coder"); app.deleteDepartment("Docs") }
        _ = app.setDepartmentInstructions("App-Coder", text: "Use SwiftUI. Name every file you touch.")
        let note = try app.addDepartmentFact("App-Coder", .init(kind: .decision, name: "Target", detail: "macOS 14 and later"))
        TeamMapStore.shared.update { s in
            var list = s.facts["App-Coder"] ?? []
            _ = try? DepartmentMemory.propose(&list, .init(kind: .term, name: "Todo", detail: "A task with a due date"), sourceAgentId: soft[1].id, sourceName: soft[1].name)
            s.facts["App-Coder"] = list
        }
        app.reloadTeamMap()
        XCTAssertEqual(app.pendingFactCount("App-Coder"), 1)
        _ = note

        try shot(TeamMapView(appState: app), size: CGSize(width: 1280, height: 780), to: out.appendingPathComponent("1-team-map.png"))
        try shot(DepartmentInstructionsSheet(appState: app, department: "App-Coder", onClose: {}), size: CGSize(width: 640, height: 520), to: out.appendingPathComponent("2-instructions.png"))
        try shot(DepartmentMemorySheet(appState: app, department: "App-Coder", onClose: {}), size: CGSize(width: 640, height: 560), to: out.appendingPathComponent("3-memory.png"))
        try shot(NewDepartmentSheet(appState: app, onClose: {}), size: CGSize(width: 560, height: 560), to: out.appendingPathComponent("4-new-department.png"))
    }
}
