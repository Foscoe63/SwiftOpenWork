import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

final class PartialRevertTests: XCTestCase {
    func testHunkRevertWritesOnlyWhenFileIsUnchangedSinceTheDiff() async throws {
        let path = NSTemporaryDirectory() + "partial-\(UUID().uuidString).txt"
        let original = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        await FileCheckpointStore.shared.beginTurn(label: "test")
        await FileCheckpointStore.shared.record(path: path)
        let edited = "a\nB\nc\nd\ne\nf\ng\nh\nI\nj\n"
        try edited.write(toFile: path, atomically: true, encoding: .utf8)

        let diff = SideBySideDiff.make(old: original, new: edited)
        XCTAssertEqual(diff.hunks.count, 2)

        // Someone else edits the file after the diff was drawn: the revert must refuse.
        try (edited + "extra\n").write(toFile: path, atomically: true, encoding: .utf8)
        var ok = await FileCheckpointStore.shared.applyPartialRevert(path: path, expectedCurrent: edited, contents: diff.reverting([0]))
        XCTAssertFalse(ok)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), edited + "extra\n")

        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        ok = await FileCheckpointStore.shared.applyPartialRevert(path: path, expectedCurrent: edited, contents: diff.reverting([0]))
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "a\nb\nc\nd\ne\nf\ng\nh\nI\nj\n")

        // The checkpoint survives, so the remaining hunk is still reviewable and revertable.
        let changes = await FileCheckpointStore.shared.changes()
        XCTAssertEqual(changes.first { $0.path == path }?.kind, .modified)

        // Untracked paths are never written.
        let other = NSTemporaryDirectory() + "untracked-\(UUID().uuidString).txt"
        try "x".write(toFile: other, atomically: true, encoding: .utf8)
        ok = await FileCheckpointStore.shared.applyPartialRevert(path: other, expectedCurrent: "x", contents: "y")
        XCTAssertFalse(ok)
        await FileCheckpointStore.shared.beginTurn()
    }
}
