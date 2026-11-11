import XCTest
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage

/// `.plain` hit-tests a button against what it *draws*, not against its frame.
///
/// This was reported twice as separate bugs — the inspector tabs, then every icon in the left
/// sidebar — before it was recognised as one rule, and then the sweep was written up in HANDOFF
/// and not done: 85 call sites stayed on `.plain`. A rule that lives only in a document is a rule
/// that gets broken by the next person, so here it is as a test.
///
/// A borderless button must either use `.hitTestable` or declare its own `contentShape`. The
/// exemptions below are buttons that deliberately hit-test against their drawing, each named with
/// the reason — adding to that list should feel bad.
final class HitTestableButtonSweepTests: XCTestCase {

    /// Buttons that keep `.plain` on purpose: each one fills its row or its frame, so widening the
    /// hit area would take clicks that belong to a neighbour. That is the exact failure the
    /// HANDOFF note warned a blanket sweep would cause.
    private static let exemptFiles: Set<String> = [
        // Full-width rows inside lists and pickers — the label already covers the frame, and
        // extending it would swallow the adjacent control.
        "ChatView.swift",
        "ComposerView.swift",
        "LocalModelsView.swift",
        "MessageBubbleView.swift",
        "SessionChangeReviewView.swift",
        // Fixed-width panels (480pt and 180pt) whose button sits inside the panel's own frame.
        "SettingsView.swift",
        "SkillsAndMcpModals.swift"
    ]

    private static var uiRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SwiftOpenWork/UI")
    }

    func testBorderlessButtonsAreClickableAcrossTheirFrame() throws {
        guard let walker = FileManager.default.enumerator(at: Self.uiRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("no Sources/UI")
        }
        var offenders: [String] = []

        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            // SettingsView's pages live in `SettingsView+<Section>.swift`; the exemption covers them too.
            if Self.exemptFiles.contains(name) || name.hasPrefix("SettingsView+") { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)

            for (index, line) in lines.enumerated() where line.contains("buttonStyle(.plain)") {
                // A `contentShape` within the label above or the modifiers just below does the
                // same job by hand, which is why six sites legitimately still say `.plain`.
                let lower = max(0, index - 20)
                let upper = min(lines.count, index + 5)
                let context = lines[lower..<upper].joined(separator: "\n")
                if context.contains("contentShape") { continue }
                offenders.append("\(name):\(index + 1)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            These borderless buttons hit-test against their drawing, so clicks landing between a \
            glyph's strokes or in a row's padding do nothing:
            \(offenders.joined(separator: "\n"))

            Use `.buttonStyle(.hitTestable)`, or add `.contentShape(Rectangle())` if the button \
            really should only respond where it draws.
            """
        )
    }

    /// The style itself has to keep doing the one thing it exists for.
    func testTheStyleDeclaresAContentShape() throws {
        let source = try String(
            contentsOf: Self.uiRoot.appendingPathComponent("Components/HitTestablePlainButtonStyle.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("contentShape(Rectangle())"))
    }
}
