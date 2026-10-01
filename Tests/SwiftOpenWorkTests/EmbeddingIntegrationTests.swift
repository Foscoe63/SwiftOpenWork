import XCTest
import os
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkLocalInference

/// Runs the real embedding model. Skipped unless `RUN_EMBEDDING_INTEGRATION=1` is in the
/// environment (`TEST_RUNNER_RUN_EMBEDDING_INTEGRATION=1` under xcodebuild), because the first run
/// downloads the model (~65 MB) and every run loads it into Metal.
final class EmbeddingIntegrationTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["RUN_EMBEDDING_INTEGRATION"] == "1" else {
            throw XCTSkip("set RUN_EMBEDDING_INTEGRATION=1 to download and run the real embedding model")
        }
    }

    private func ensureModel() async throws {
        let service = MLXEmbeddingService.shared
        guard !service.isDownloaded() else { return }
        let last = OSAllocatedUnfairLock(initialState: -1)
        try await service.download { fraction, message in
            let pct = Int(fraction * 100)
            let shouldPrint = last.withLock { previous -> Bool in
                defer { previous = pct }
                return pct / 10 != previous / 10
            }
            if shouldPrint { print("EMB-DOWNLOAD \(message)") }
        }
        XCTAssertTrue(service.isDownloaded(), "download finished but the model is not where the resolver looks")
    }

    func testRealModelEmbedsAndRanksBySemantics() async throws {
        try requireOptIn()
        try await ensureModel()
        let service = MLXEmbeddingService.shared

        let docs = [
            "func handleLogin(user: String, password: String) { verifyCredentials(user, password); issueSessionToken() }",
            "func openSocket(host: String) { connect(host); sendPacket(); closeConnection() }",
            "func resizeImage(pixels: [UInt8], width: Int) { scaleBitmap() }",
        ]
        let vectors = try await service.embed(docs, isQuery: false)
        XCTAssertEqual(vectors.count, 3)
        let dimension = vectors[0].count
        print("EMB-DIM \(dimension)")
        XCTAssertGreaterThan(dimension, 100)
        for v in vectors {
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            XCTAssertEqual(norm, 1, accuracy: 0.01, "vectors must be unit length for dot == cosine")
        }

        let query = try await service.embed(["how do users authenticate"], isQuery: true)[0]
        let scores = vectors.map { zip($0, query).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        print("EMB-SCORES auth=\(scores[0]) net=\(scores[1]) img=\(scores[2])")
        XCTAssertGreaterThan(scores[0], scores[1])
        XCTAssertGreaterThan(scores[0], scores[2])

        // Identical text must embed identically regardless of batch composition (padding mask).
        let alone = try await service.embed([docs[1]], isQuery: false)[0]
        let cosine = zip(alone, vectors[1]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        print("EMB-BATCH-INVARIANCE cos=\(cosine)")
        XCTAssertGreaterThan(cosine, 0.99)
    }

    /// The claim the feature makes: a query that shares no word with the code still finds it.
    func testHybridSearchFindsCodeThatSharesNoKeywordWithTheQuery() async throws {
        try requireOptIn()
        try await ensureModel()

        let root = NSTemporaryDirectory() + "hybrid-real-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files: [String: String] = [
            "session.swift": "func handleLogin(user: String, password: String) {\n    verifyCredentials(user, password)\n    issueSessionToken()\n}\n",
            "network.swift": "func openSocket(host: String) {\n    connect(host)\n    sendPacket()\n    closeConnection()\n}\n",
            "images.swift": "func resizeImage(pixels: [UInt8], width: Int) {\n    scaleBitmap()\n}\n",
            "storage.swift": "func saveRecord(row: Row) {\n    openDatabase()\n    insertIntoTable(row)\n    commitTransaction()\n}\n",
        ]
        for (name, text) in files { try text.write(toFile: root + "/" + name, atomically: true, encoding: .utf8) }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "emb-real-\(UUID().uuidString)")
        let hybrid = CodeIndex(
            semanticEnabled: { true }, embedderProvider: { MLXEmbeddingService.shared }, storeDirectory: dir
        )
        let lexical = CodeIndex(semanticEnabled: { false }, embedderProvider: { nil }, storeDirectory: dir)

        let query = "who is allowed to sign in"
        let lexicalHits = await lexical.search(query: query, root: root)
        print("HYB-LEXICAL-ONLY \(lexicalHits.map(\.chunk.path))")
        XCTAssertTrue(lexicalHits.isEmpty, "the premise: no keyword in common, so BM25 alone finds nothing")

        // First search starts the background build; wait for it, then search again.
        _ = await hybrid.search(query: query, root: root)
        await hybrid.waitForEmbeddings(root: root)
        let result = await hybrid.searchWithStatus(query: query, root: root)
        print("HYB-HYBRID \(result.hits.map(\.chunk.path)) note=\(result.note ?? "none")")
        XCTAssertEqual(result.hits.first?.chunk.path, "session.swift")
        XCTAssertNil(result.note, "vectors are complete, so there should be no keyword-only caveat")

        let second = await hybrid.searchWithStatus(query: "store data in a database", root: root)
        print("HYB-HYBRID-2 \(second.hits.map(\.chunk.path))")
        XCTAssertEqual(second.hits.first?.chunk.path, "storage.swift")

        // Vectors must have been cached to disk and be reused by a fresh index.
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        print("HYB-CACHE-FILES \(cached)")
        XCTAssertFalse(cached.isEmpty)
    }
}
