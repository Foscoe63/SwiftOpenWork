import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// `NoDeadSettingsTests` enforced "nothing ships with a control until something reads it" — for
/// fields of `AppSettings`. Two sweeps ran under that rule and both missed the largest dead
/// surface in the app, because it was not a setting.
///
/// `AutomationTriggerType` declared five triggers. Exactly one, `.manual`, was consumed anywhere,
/// and only to decide whether to *draw* a next-run line. The Automations screen rendered
/// "Next run: Tomorrow at 9:00 AM" beside a clock for schedules nothing would ever fire, and the
/// seeded automations shipped with "Daily at 9:00 AM" and "On File Change".
///
/// So the rule generalises: a case of a user-facing enum is a promise, exactly like a switch is.
/// These tests read the sources, because a case is only alive if some *other* file acts on it.
final class NoDeadFeaturesTests: XCTestCase {

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Text of every source file except the one declaring the type under test.
    private func sourcesExcluding(_ declaringFile: String) throws -> String {
        try swiftFiles()
            .filter { $0.lastPathComponent != declaringFile }
            .map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
            .joined(separator: "\n")
    }

    // MARK: - Automation triggers

    /// Every trigger the Automations screen offers has to be something that fires.
    func testEveryAutomationTriggerHasSomethingThatFiresIt() throws {
        let sources = try sourcesExcluding("Automation.swift")
        for trigger in AutomationTriggerType.allCases {
            XCTAssertTrue(
                sources.contains(".\(trigger.rawValue)"),
                """
                AutomationTriggerType.\(trigger.rawValue) is offered in the trigger picker and \
                nothing outside the model reads it. Either wire it in AutomationScheduler or take \
                the case out of the picker — a trigger that cannot fire is a promise the app breaks.
                """
            )
        }
    }

    /// The scheduler must name every trigger it is responsible for. A case added later that the
    /// scheduler never learned about would pass the test above on the strength of the UI alone.
    func testTheSchedulerHandlesEveryNonManualTrigger() throws {
        let scheduler = try String(
            contentsOf: SourceTree.url("Engine/Automations/AutomationScheduler.swift"),
            encoding: .utf8
        )
        for trigger in AutomationTriggerType.allCases where trigger != .manual {
            XCTAssertTrue(
                scheduler.contains(".\(trigger.rawValue)"),
                "AutomationScheduler never mentions .\(trigger.rawValue), so nothing fires it"
            )
        }
    }

    // MARK: - Tools

    /// Every tool the app seeds must have an implementation.
    ///
    /// A declared tool with no `case` reaches the model as a callable function and comes back
    /// "unknown tool" — the model then retries it, because nothing said the attempt was hopeless.
    func testEverySeededToolIsImplemented() throws {
        let engine = try SourceTree.toolEngineSource()
        let declarations = try String(
            contentsOf: SourceTree.url("Storage/PersistenceManager.swift"),
            encoding: .utf8
        )
        let catalog = try String(
            contentsOf: SourceTree.url("Engine/Tools/ToolSchemaCatalog.swift"),
            encoding: .utf8
        )

        for name in Self.toolNames(in: declarations) + Self.toolNames(in: catalog) {
            XCTAssertTrue(
                engine.contains("\"\(name)\""),
                "tool '\(name)' is declared but ToolExecutionEngine never handles it"
            )
        }
    }

    /// Tools removed for not doing what they claimed must stay removed, and must be stripped from
    /// installs that already saved them — `defaultTools` seeds a list, it does not prune one.
    func testRetiredToolsAreNotSeededAndAreStrippedOnLoad() throws {
        let declarations = try String(
            contentsOf: SourceTree.url("Storage/PersistenceManager.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            Self.toolNames(in: declarations).contains("generate_image"),
            "generate_image wrote a fixed SVG regardless of the prompt; it must not be seeded again"
        )
        XCTAssertTrue(
            declarations.contains("let retired: Set<String> = [\"generate_image\"]"),
            "existing installs keep offering a retired tool unless loadTools strips it"
        )
    }

    /// A tool whose description promises something its implementation cannot do is the same fault
    /// as a switch that reads nothing — the model believes the description.
    ///
    /// Pinned by name because both of these shipped that way: `mlx_vision_describe` claimed local
    /// MLX vision models and ran Apple Vision OCR, and `image_analyze` claimed to detect "labels
    /// and structured components" when it returns recognised text.
    func testVisionToolDescriptionsMatchWhatTheyDo() throws {
        let declarations = try String(
            contentsOf: SourceTree.url("Storage/PersistenceManager.swift"),
            encoding: .utf8
        )
        let describeLine = try XCTUnwrap(
            declarations.split(separator: "\n").first { $0.contains("id: \"mlx_vision_describe\"") }
        )
        XCTAssertTrue(
            describeLine.contains("OCR") && describeLine.contains("vision model"),
            "mlx_vision_describe's description must say what it does when no vision model is loaded"
        )

        let analyzeLine = try XCTUnwrap(
            declarations.split(separator: "\n").first { $0.contains("id: \"image_analyze\"") }
        )
        XCTAssertFalse(
            analyzeLine.localizedCaseInsensitiveContains("bounding box")
                || analyzeLine.localizedCaseInsensitiveContains("structured component"),
            "image_analyze returns OCR text; it must not claim to detect boxes or components"
        )
    }

    // MARK: - Controls that must control something

    /// The same rule as a dead setting, applied to a segmented control.
    ///
    /// `VisualDiffInspectorView` offered "Side-by-Side / Unified Diff", defaulted to Side-by-Side,
    /// and always rendered unified. The picker bound to `@State` that no other line read, so the
    /// control was not merely broken — it stated, as its resting position, something untrue about
    /// what was on screen.
    func testTheDiffViewModePickerDrivesWhatIsRendered() throws {
        let view = try String(
            contentsOf: SourceTree.url("UI/Views/Artifacts/VisualDiffInspectorView.swift"),
            encoding: .utf8
        )
        let readsOutsideTheBinding = view.contains("viewMode == .split")
            || view.contains("switch viewMode")
        XCTAssertTrue(
            readsOutsideTheBinding,
            "the Side-by-Side / Unified picker must decide what the body renders, not just store a value"
        )
        XCTAssertTrue(
            view.contains("splitBody"),
            "there has to be a side-by-side rendering for the picker's default option to mean anything"
        )
    }

    /// A button that claims to save must save. In the turn review sheet the agent had already
    /// written the file, `onAccept` was `{}`, and "Apply & Save Changes" did nothing at all.
    func testTheTurnReviewSheetDoesNotOfferAnApplyButtonThatSavesNothing() throws {
        let view = try String(
            contentsOf: SourceTree.url("UI/Views/Chat/TurnChangeReviewView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            view.contains("onAccept: {}"),
            "an empty onAccept renders a prominent button that does nothing when pressed"
        )
        XCTAssertTrue(
            view.contains("onAccept: nil"),
            "the change is already on disk here, so the sheet should not offer to apply it"
        )
    }

    private static func toolNames(in source: String) -> [String] {
        let pattern = #"Tool\(\s*\n?\s*id: "([a-z_0-9]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
