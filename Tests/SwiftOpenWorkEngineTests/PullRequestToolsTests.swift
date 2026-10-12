import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

final class PullRequestToolsTests: XCTestCase {
    private let sample = """
    {"number":42,"title":"Add hooks","url":"https://github.com/o/r/pull/42","state":"OPEN","isDraft":false,
     "reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/hooks",
     "statusCheckRollup":[
       {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://x/1"},
       {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://x/2"},
       {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":""},
       {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"},
       {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":"https://x/3"}]}
    """

    func testParsesChecksOfBothShapes() throws {
        let status = try XCTUnwrap(PullRequestTools.parseStatus(sample))
        XCTAssertEqual(status.number, 42)
        XCTAssertEqual(status.branch, "feature/hooks")
        let states = Dictionary(uniqueKeysWithValues: status.checks.map { ($0.name, $0.state) })
        XCTAssertEqual(states["build"], .passing)
        XCTAssertEqual(states["test"], .failing)
        XCTAssertEqual(states["lint"], .pending)
        XCTAssertEqual(states["docs"], .skipped)
        XCTAssertEqual(states["ci/legacy"], .passing)
    }

    func testSummaryLeadsWithTheWorstNews() throws {
        var status = try XCTUnwrap(PullRequestTools.parseStatus(sample))
        XCTAssertEqual(status.summary, "#42 · 1 failing · changes requested")
        status.checks.removeAll { $0.state == .failing }
        XCTAssertEqual(status.summary, "#42 · 1 running · changes requested")
        status.checks.removeAll { $0.state == .pending }
        status.reviewDecision = nil
        XCTAssertEqual(status.summary, "#42 · checks passing")
        status.isDraft = true
        XCTAssertTrue(status.summary.contains("draft"))
    }

    func testCancelledAndTimedOutCountAsFailures() {
        for conclusion in ["CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"] {
            XCTAssertEqual(PullRequestTools.checkState(["status": "COMPLETED", "conclusion": conclusion]), .failing, conclusion)
        }
    }

    func testGarbageIsNotAStatus() {
        XCTAssertNil(PullRequestTools.parseStatus("not json"))
        XCTAssertNil(PullRequestTools.parseStatus("{\"title\":\"x\"}"))
    }

    func testToolsAreRegisteredGatedAndBlockedInPlanMode() {
        XCTAssertTrue(ToolCallRepair.builtInNames.contains("pr_status"))
        XCTAssertTrue(ToolCallRepair.builtInNames.contains("pr_create"))
        XCTAssertTrue(ToolCallRepair.isBlockedInPlanMode("pr_create"))
        XCTAssertFalse(ToolCallRepair.isBlockedInPlanMode("pr_status"))
        let names = Set(ToolSchemaCatalog.parityDefaults.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["pr_status", "pr_create"]))
    }

    @MainActor
    func testCreatingAPullRequestAlwaysAsksEvenWhenShellIsUnrestricted() {
        var settings = AppSettings()
        settings.terminalSafetyLevel = .allowAll
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "pr_create", argumentsJson: "{}", settings: settings))
        XCTAssertNil(AgentRunner.approvalReason(toolName: "pr_status", argumentsJson: "{}", settings: settings))
    }

    func testCreateRefusesWithoutGitHubCLIOrOnABaseBranch() async throws {
        let root = ToolExecutionEngine.canonicalPath(NSTemporaryDirectory()) + "/pr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Not a repository: nothing to push, so nothing may be attempted.
        let result = await PullRequestTools.create(in: root, title: "t", body: "b", base: nil, draft: false)
        XCTAssertFalse(result.success)
    }
}

final class ReviewCommentsTests: XCTestCase {
    func testBatchPromptGroupsByFileInLineOrderAndSkipsBlankNotes() {
        let prompt = ReviewComment.prompt(for: [
            ReviewComment(path: "b.swift", line: 9, excerpt: "let x = 1", text: "name this better"),
            ReviewComment(path: "a.swift", line: 30, excerpt: "foo()", text: "handle the error"),
            ReviewComment(path: "a.swift", line: 4, excerpt: "", text: "why a global?"),
            ReviewComment(path: "a.swift", line: 5, excerpt: "x", text: "   "),
        ])
        XCTAssertTrue(prompt.contains("3 comments"))
        let a = prompt.range(of: "### a.swift")!.lowerBound, b = prompt.range(of: "### b.swift")!.lowerBound
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(prompt.range(of: "line 4")!.lowerBound, prompt.range(of: "line 30")!.lowerBound)
        XCTAssertTrue(prompt.contains("line 9 (`let x = 1`): name this better"))
    }

    func testNoCommentsNoPrompt() {
        XCTAssertEqual(ReviewComment.prompt(for: []), "")
    }
}

final class TurnCostTests: XCTestCase {
    func testPricedFromTheModelsOwnRates() {
        let model = ModelInfo(id: "m", name: "m", costPer1kPrompt: 0.003, costPer1kCompletion: 0.015)
        XCTAssertEqual(TurnCost.usd(model: model, promptTokens: 10_000, completionTokens: 2_000), 0.06, accuracy: 0.0001)
    }

    func testALocalModelIsFreeSoALimitNeverStopsIt() {
        let local = ModelInfo(id: "l", name: "l")
        let spent = TurnCost.usd(model: local, promptTokens: 50_000_000, completionTokens: 9_000_000)
        XCTAssertEqual(spent, 0)
        XCTAssertFalse(TurnCost.exceeds(limit: 0.01, spent: spent))
    }

    func testZeroMeansNoLimit() {
        XCTAssertFalse(TurnCost.exceeds(limit: 0, spent: 1_000))
        XCTAssertTrue(TurnCost.exceeds(limit: 5, spent: 5.01))
        XCTAssertFalse(TurnCost.exceeds(limit: 5, spent: 5))
    }

    func testFormatting() {
        XCTAssertEqual(TurnCost.format(1.5), "$1.50")
        XCTAssertEqual(TurnCost.format(0.0031), "$0.0031")
    }
}

@MainActor
final class DocumentWriterTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let markdown = "# Report\n\nSome **bold** and *italic* text with `code`.\n\n- one\n- two\n\n| Name | Qty |\n|---|---|\n| apples | 3 |\n"

    func testMarkdownBecomesHTML() {
        let html = DocumentWriter.html(fromMarkdown: markdown)
        XCTAssertTrue(html.contains("<h1>Report</h1>"))
        XCTAssertTrue(html.contains("<b>bold</b>") && html.contains("<i>italic</i>") && html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<th>Name</th>") && html.contains("<td>apples</td>"))
        XCTAssertFalse(html.contains("---"), "the table separator row is not data")
        XCTAssertTrue(DocumentWriter.html(fromMarkdown: "<script>alert(1)</script>").contains("&lt;script&gt;"), "markup in the text is escaped")
    }

    func testWritesAWordFileThatIsAValidZipWithTheText() throws {
        let url = dir.appendingPathComponent("r.docx")
        try DocumentWriter.write(content: markdown, to: url, format: .docx)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "a .docx is a zip")
        let text = try XCTUnwrap(NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)).string
        XCTAssertTrue(text.contains("Report") && text.contains("apples"))
    }

    func testWritesPDFRTFAndHTML() throws {
        for format in [DocumentWriter.Format.pdf, .rtf, .html] {
            let url = dir.appendingPathComponent("r.\(format.rawValue)")
            try DocumentWriter.write(content: markdown, to: url, format: format)
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 100, format.rawValue)
        }
        XCTAssertTrue(try Data(contentsOf: dir.appendingPathComponent("r.pdf")).starts(with: Data("%PDF".utf8)))
    }

    func testALongDocumentGetsMorePages() throws {
        let long = (0..<400).map { "Paragraph number \($0) with some words in it." }.joined(separator: "\n\n")
        let url = dir.appendingPathComponent("long.pdf")
        try DocumentWriter.write(content: long, to: url, format: .pdf)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertGreaterThan(document.numberOfPages, 3)
    }

    func testSpreadsheetFromCSVHasQuotedFieldsNumbersAndFormulas() throws {
        let csv = "item,qty,total\n\"Widget, large\",3,=B2*2\n007,4,x\n"
        XCTAssertEqual(DocumentWriter.parseCSV(csv)[1], ["Widget, large", "3", "=B2*2"])
        let xml = DocumentWriter.sheetXML(rows: DocumentWriter.rows(from: csv))
        XCTAssertTrue(xml.contains("<f>B2*2</f>"))
        XCTAssertTrue(xml.contains("<v>3</v>"))
        XCTAssertTrue(xml.contains(">007<"), "a leading-zero code stays text")
        let url = dir.appendingPathComponent("s.xlsx")
        try DocumentWriter.write(content: csv, to: url, format: .xlsx)
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-l", url.path]
        let pipe = Pipe(); listing.standardOutput = pipe
        try listing.run(); listing.waitUntilExit()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(names.contains("xl/worksheets/sheet1.xml") && names.contains("[Content_Types].xml"))
    }

    func testMarkdownTableAlsoMakesASpreadsheet() {
        XCTAssertEqual(DocumentWriter.rows(from: "| a | b |\n|---|---|\n| 1 | 2 |"), [["a", "b"], ["1", "2"]])
    }

    func testToolIsRegisteredGatedAndBlockedInPlanMode() {
        XCTAssertTrue(ToolCallRepair.builtInNames.contains("document_create"))
        XCTAssertTrue(ToolCallRepair.isBlockedInPlanMode("document_create"))
        var settings = AppSettings(); settings.terminalSafetyLevel = .allowAll
        XCTAssertNotNil(AgentRunner.approvalReason(toolName: "document_create", argumentsJson: "{}", settings: settings))
        XCTAssertNil(DocumentWriter.Format(path: "notes.txt"))
    }

    func testTheToolWritesThroughTheEngine() async throws {
        var workspace = Workspace.default
        workspace.folderPath = ToolExecutionEngine.canonicalPath(dir.path)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "out/report.docx", "content": markdown]), as: UTF8.self)
        let result = await ToolExecutionEngine.shared.execute(toolName: "document_create", argumentsJson: json, workspace: workspace, currentAgent: Agent(name: "T"))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path + "/out/report.docx"))
        let bad = await ToolExecutionEngine.shared.execute(toolName: "document_create", argumentsJson: #"{"path":"x.txt","content":"a"}"#, workspace: workspace, currentAgent: Agent(name: "T"))
        XCTAssertFalse(bad.success)
    }
}
