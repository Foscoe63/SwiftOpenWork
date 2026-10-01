import XCTest
@testable import SwiftOpenWorkCore

final class SideBySideDiffTests: XCTestCase {
    private func lines(_ n: Int, replacing: [Int: String] = [:]) -> String {
        (1...n).map { replacing[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func testIdenticalTextHasNoHunksAndNoRows() {
        let diff = SideBySideDiff.make(old: "a\nb\n", new: "a\nb\n")
        XCTAssertTrue(diff.isEmpty)
        XCTAssertTrue(diff.rows.isEmpty)
    }

    func testChangedLinePairsLeftAndRight() {
        let diff = SideBySideDiff.make(old: "a\nb\nc\n", new: "a\nB\nc\n")
        XCTAssertEqual(diff.hunks.count, 1)
        let changed = diff.rows.first { $0.kind == .changed }
        XCTAssertEqual(changed?.leftText, "b")
        XCTAssertEqual(changed?.rightText, "B")
        XCTAssertEqual(changed?.leftNumber, 2)
        XCTAssertEqual(changed?.rightNumber, 2)
    }

    func testPureAdditionAndRemovalAreOneSided() {
        let added = SideBySideDiff.make(old: "a\nc\n", new: "a\nb\nc\n")
        XCTAssertEqual(added.rows.first { $0.kind == .added }?.rightText, "b")
        XCTAssertNil(added.rows.first { $0.kind == .added }?.leftText)
        let removed = SideBySideDiff.make(old: "a\nb\nc\n", new: "a\nc\n")
        XCTAssertEqual(removed.rows.first { $0.kind == .removed }?.leftText, "b")
    }

    func testDistantEditsAreSeparateHunksAndLongContextCollapses() {
        let old = lines(100)
        let new = lines(100, replacing: [5: "FIVE", 90: "NINETY"])
        let diff = SideBySideDiff.make(old: old, new: new)
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertTrue(diff.rows.contains { if case .gap = $0.kind { return true } else { return false } })
        XCTAssertLessThan(diff.rows.count, 30, "an untouched middle must not be rendered")
        // Row ids are unique and hunks point at a real row.
        XCTAssertEqual(Set(diff.rows.map(\.id)).count, diff.rows.count)
        for hunk in diff.hunks { XCTAssertEqual(diff.rows[hunk.firstRowId].hunk, hunk.id) }
    }

    func testRevertingOneHunkLeavesTheOtherAsWritten() {
        let old = lines(100)
        let new = lines(100, replacing: [5: "FIVE", 90: "NINETY"])
        let diff = SideBySideDiff.make(old: old, new: new)
        XCTAssertEqual(diff.reverting([0]), lines(100, replacing: [90: "NINETY"]))
        XCTAssertEqual(diff.reverting([1]), lines(100, replacing: [5: "FIVE"]))
        XCTAssertEqual(diff.reverting([]), new)
        XCTAssertEqual(diff.reverting([0, 1]), old)
    }

    func testRevertingHunksThatChangeLineCounts() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"
        // Delete b, insert two lines after g, replace k.
        let new = "a\nc\nd\ne\nf\ng\nX\nY\nh\ni\nj\nK\nl\n"
        let diff = SideBySideDiff.make(old: old, new: new)
        XCTAssertEqual(diff.hunks.count, 3)
        for subset in [Set([0]), Set([1]), Set([2]), Set([0, 2]), Set([1, 2]), Set([0, 1])] {
            var expected = diff.hunks.map(\.id)
            expected.removeAll { subset.contains($0) }
            // Reverting a subset then diffing against old must leave exactly the others.
            let partial = diff.reverting(subset)
            let again = SideBySideDiff.make(old: old, new: partial)
            XCTAssertEqual(again.hunks.count, expected.count, "subset \(subset)")
        }
    }

    func testCreatedAndDeletedFiles() {
        let created = SideBySideDiff.make(old: nil, new: "x\ny\n")
        XCTAssertEqual(created.hunks.count, 1)
        XCTAssertEqual(created.reverting([0]), "")
        let deleted = SideBySideDiff.make(old: "x\ny\n", new: nil)
        XCTAssertEqual(deleted.hunks.first?.removedLines, ["x", "y"])
        XCTAssertEqual(deleted.reverting([0]), "x\ny\n")
    }

    func testMissingTrailingNewlineIsPreserved() {
        let diff = SideBySideDiff.make(old: "a\nb\nc", new: "a\nB\nc")
        XCTAssertEqual(diff.reverting([]), "a\nB\nc")
    }

    func testHugeDifferingFilesFallBackToOneBlockInsteadOfExhaustingMemory() {
        let old = (0..<3000).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<3000).map { "new \($0)" }.joined(separator: "\n")
        let diff = SideBySideDiff.make(old: old, new: new)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.reverting([0]), old)
    }
}
