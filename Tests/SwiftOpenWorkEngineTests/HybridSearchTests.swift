import XCTest
@testable import SwiftOpenWorkEngine
import SwiftOpenWorkCore

/// Embeds by topic keyword so "login" and "authentication" land on the same axis, which is exactly
/// what BM25 cannot do.
private struct TopicEmbedder: TextEmbedder {
    let identifier = "test-topic"
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        texts.map { text in
            let t = text.lowercased()
            let auth: Float = (t.contains("login") || t.contains("authentication") || t.contains("password")) ? 1 : 0
            let net: Float = (t.contains("socket") || t.contains("network")) ? 1 : 0
            return HybridRanking.normalized([auth, net, 0.05])
        }
    }
}

private struct FailingEmbedder: TextEmbedder {
    let identifier = "fail"
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "model missing"])
    }
}

final class HybridSearchTests: XCTestCase {
    private func makeRepo() throws -> String {
        let root = NSTemporaryDirectory() + "hybrid-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "func handleLogin(user: String) { checkPassword(user) }".write(toFile: root + "/session.swift", atomically: true, encoding: .utf8)
        try "func openSocket() { connectNetwork() }".write(toFile: root + "/net.swift", atomically: true, encoding: .utf8)
        return root
    }

    private func makeIndex(embedder: (any TextEmbedder)?, enabled: Bool = true) -> CodeIndex {
        CodeIndex(
            semanticEnabled: { enabled },
            embedderProvider: { embedder },
            storeDirectory: URL(fileURLWithPath: NSTemporaryDirectory() + "emb-\(UUID().uuidString)")
        )
    }

    func testSemanticMatchFindsFileWithNoSharedKeyword() async throws {
        let root = try makeRepo()
        let index = makeIndex(embedder: TopicEmbedder())
        // "authentication" appears in neither file, so BM25 alone returns nothing.
        let lexicalOnly = await makeIndex(embedder: nil, enabled: false).search(query: "authentication", root: root)
        XCTAssertTrue(lexicalOnly.isEmpty)

        _ = await index.search(query: "authentication", root: root)   // starts the background build
        await index.waitForEmbeddings(root: root)
        let hits = await index.search(query: "authentication", root: root)
        XCTAssertEqual(hits.first?.chunk.path, "session.swift")
    }

    func testDisabledOrMissingEmbedderStaysLexical() async throws {
        let root = try makeRepo()
        let off = await makeIndex(embedder: TopicEmbedder(), enabled: false).searchWithStatus(query: "socket", root: root)
        XCTAssertEqual(off.hits.first?.chunk.path, "net.swift")
        XCTAssertNil(off.note)

        let missing = await makeIndex(embedder: nil).searchWithStatus(query: "socket", root: root)
        XCTAssertEqual(missing.hits.first?.chunk.path, "net.swift")
        XCTAssertNotNil(missing.note)
    }

    func testFailingEmbedderFallsBackToBM25WithANote() async throws {
        let root = try makeRepo()
        let index = makeIndex(embedder: FailingEmbedder())
        _ = await index.search(query: "socket", root: root)
        await index.waitForEmbeddings(root: root)
        let result = await index.searchWithStatus(query: "socket", root: root)
        XCTAssertEqual(result.hits.first?.chunk.path, "net.swift")
        XCTAssertTrue(result.note?.contains("model missing") ?? false)
    }

    func testVectorsSurviveARestartAndOnlyChangedChunksAreReEmbedded() async throws {
        let root = try makeRepo()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "emb-\(UUID().uuidString)")
        let counting = CountingEmbedder()
        func fresh() -> CodeIndex {
            CodeIndex(semanticEnabled: { true }, embedderProvider: { counting }, storeDirectory: dir)
        }
        let first = fresh()
        _ = await first.search(query: "socket", root: root)
        await first.waitForEmbeddings(root: root)
        let afterFirst = counting.documentsEmbedded
        XCTAssertEqual(afterFirst, 2)

        let second = fresh()
        _ = await second.search(query: "socket", root: root)
        await second.waitForEmbeddings(root: root)
        XCTAssertEqual(counting.documentsEmbedded, afterFirst, "unchanged chunks must come from the cache")
    }

    func testReciprocalRankFusionRewardsAgreement() {
        // 5 is first in both lists, 0 and 1 each first in one.
        let fused = HybridRanking.reciprocalRankFusion([[5, 0, 2], [5, 1, 3]], topK: 5)
        XCTAssertEqual(fused.first?.index, 5)
        XCTAssertEqual(Set(fused.map(\.index)), [5, 0, 1, 2, 3])
        XCTAssertEqual(HybridRanking.reciprocalRankFusion([[5, 0, 2], [5, 1, 3]], topK: 2).count, 2)
    }

    func testStoreRoundTripsAndRejectsGarbage() {
        var store = EmbeddingStore()
        store.insert([0.5, 0.25, 1], forKey: EmbeddingStore.key(for: "a"))
        store.insert([1, 2, 3], forKey: EmbeddingStore.key(for: "b"))
        let restored = EmbeddingStore(data: store.serialized())
        XCTAssertEqual(restored?.count, 2)
        XCTAssertEqual(restored?.vector(forKey: EmbeddingStore.key(for: "b")), [1, 2, 3])
        XCTAssertNil(EmbeddingStore(data: Data("junk".utf8)))
        XCTAssertNil(EmbeddingStore(data: store.serialized().dropLast(5)))
    }
}

private final class CountingEmbedder: TextEmbedder, @unchecked Sendable {
    let identifier = "counting"
    private let lock = NSLock()
    private var count = 0
    var documentsEmbedded: Int { lock.withLock { count } }
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        if !isQuery { lock.withLock { count += texts.count } }
        return texts.map { _ in [1, 0, 0] }
    }
}
