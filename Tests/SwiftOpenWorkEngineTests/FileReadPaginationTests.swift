import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// End-to-end coverage for the read path, through `ToolExecutionEngine.execute` rather than the
/// private helper — the bug being fixed was that a caller could not reach past line ~250 of a
/// file, and only the public entry point proves that is no longer true.
final class FileReadPaginationTests: XCTestCase {

    private var root = ""
    private var workspace: Workspace!
    private let agent = Agent(name: "Test")

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "fileread-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        workspace = Workspace(name: "Test", folderPath: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 3,000 numbered lines: far past both the old 10,000-character cap and the new line default.
    private func writeLargeFile(lines: Int = 3_000) throws -> String {
        let name = "Large.swift"
        let body = (1...lines).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        try body.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
        return name
    }

    private func read(_ args: [String: Any]) async -> ToolExecutionResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return await ToolExecutionEngine.shared.execute(
            toolName: "file_read",
            argumentsJson: json,
            workspace: workspace,
            currentAgent: agent
        )
    }

    func testReadIsNumberedAndReportsTotalLines() async throws {
        let name = try writeLargeFile()
        let result = await read(["path": name])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("3000 lines"), "header should state the real total")
        XCTAssertTrue(result.output.contains("1\tlet value1 = 1"), "lines should be numbered")
    }

    /// The regression itself: the tail of a large file must be reachable.
    func testTailOfLargeFileIsReachable() async throws {
        let name = try writeLargeFile()
        let result = await read(["path": name, "offset": 2_900])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("let value3000 = 3000"), "last line must be readable")
        XCTAssertFalse(result.output.contains("let value1 = 1"))
    }

    func testPagingCoversEveryLine() async throws {
        let name = try writeLargeFile()
        var seen = Set<Int>()
        var offset = 1
        // Three pages of 1,000 is enough for 3,000 lines; the loop bound guards a regression
        // that would otherwise spin.
        for _ in 0..<5 {
            let result = await read(["path": name, "offset": offset, "limit": 1_000])
            guard result.success else { break }
            for line in 1...3_000 where result.output.contains("let value\(line) = \(line)\n")
                || result.output.hasSuffix("let value\(line) = \(line)") {
                seen.insert(line)
            }
            guard result.output.contains("Continue with offset=") else { break }
            offset += 1_000
        }
        XCTAssertTrue(seen.contains(1))
        XCTAssertTrue(seen.contains(1_500))
        XCTAssertTrue(seen.contains(3_000))
    }

    func testTruncationTellsTheCallerHowToContinue() async throws {
        let name = try writeLargeFile()
        let result = await read(["path": name, "limit": 10])

        // A window smaller than `minReadWindow` is widened to it: another round costs more than the lines.
        let shown = ToolExecutionEngine.minReadWindow
        XCTAssertTrue(result.output.contains("\(3_000 - shown) more lines"))
        XCTAssertTrue(result.output.contains("offset=\(shown + 1)"), "must name the next offset explicitly")
    }

    func testWholeSmallFileHasNoContinuationNotice() async throws {
        try "one\ntwo\nthree".write(toFile: root + "/small.txt", atomically: true, encoding: .utf8)
        let result = await read(["path": "small.txt"])

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.output.contains("more lines"))
        XCTAssertTrue(result.output.contains("3\tthree"))
    }

    func testOffsetPastEndIsAnError() async throws {
        try "one\ntwo".write(toFile: root + "/tiny.txt", atomically: true, encoding: .utf8)
        let result = await read(["path": "tiny.txt", "offset": 500])

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("past the end"))
    }

    func testMissingFilePointsAtGlob() async throws {
        let result = await read(["path": "nope.swift"])

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("glob"), "error should name the recovery tool")
    }

    func testOverlongLinesAreClipped() async throws {
        let huge = String(repeating: "x", count: 5_000)
        try "short\n\(huge)".write(toFile: root + "/wide.txt", atomically: true, encoding: .utf8)
        let result = await read(["path": "wide.txt"])

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("[line clipped]"))
        XCTAssertLessThan(result.output.count, 5_000)
    }
}
