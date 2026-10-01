import Foundation
import Accelerate
import CryptoKit
import os
import SwiftOpenWorkCore

/// Where the engine finds the embedding model. The engine does not link MLX; the app registers
/// one at launch, as it does for the chat engine. With none registered, search stays on BM25.
public enum EmbedderRegistry {
    private static let current = OSAllocatedUnfairLock<(any TextEmbedder)?>(initialState: nil)

    public static func register(_ embedder: (any TextEmbedder)?) {
        current.withLock { $0 = embedder }
    }

    public static var embedder: (any TextEmbedder)? {
        current.withLock { $0 }
    }
}

/// Vectors keyed by the hash of the chunk text that produced them, kept on disk per workspace and
/// embedding model.
///
/// Keying by content rather than by path means an edit re-embeds only the chunks whose text
/// changed, a moved or renamed file costs nothing, and identical chunks are embedded once.
struct EmbeddingStore {
    private(set) var vectors: [String: [Float]] = [:]
    private(set) var dimension = 0

    static func key(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var count: Int { vectors.count }

    func vector(forKey key: String) -> [Float]? { vectors[key] }

    mutating func insert(_ vector: [Float], forKey key: String) {
        if dimension == 0 { dimension = vector.count }
        guard vector.count == dimension else { return }
        vectors[key] = vector
    }

    /// Keep only what a current chunk still refers to, so the file does not grow without bound.
    mutating func retain(keys: Set<String>) {
        vectors = vectors.filter { keys.contains($0.key) }
    }

    // MARK: Persistence
    //
    // Layout: "SOEV1\n", UInt32 dimension, UInt32 count, then per entry a 64-byte hex key and
    // `dimension` Float32 values. Little-endian, which is every Mac this runs on.

    private static let magic = Data("SOEV1\n".utf8)

    func serialized() -> Data {
        var data = Self.magic
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(dimension))
        append(UInt32(vectors.count))
        for (key, vector) in vectors.sorted(by: { $0.key < $1.key }) {
            data.append(contentsOf: Array(key.utf8))
            vector.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    init() {}

    init?(data: Data) {
        guard data.starts(with: Self.magic) else { return nil }
        var offset = Self.magic.count
        func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        guard let dim = readUInt32(), let count = readUInt32() else { return nil }
        let dimension = Int(dim)
        let entryBytes = 64 + dimension * MemoryLayout<Float>.size
        guard dimension > 0, data.count - offset >= Int(count) * entryBytes else { return nil }
        self.dimension = dimension
        for _ in 0..<Int(count) {
            guard let key = String(data: data.subdata(in: offset..<offset + 64), encoding: .utf8) else { return nil }
            offset += 64
            let vector = data.subdata(in: offset..<offset + dimension * 4).withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
            offset += dimension * 4
            vectors[key] = vector
        }
    }

    static func fileURL(root: String, embedderId: String, in directory: URL) -> URL {
        let name = SHA256.hash(data: Data("\(root)|\(embedderId)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).soev")
    }

    static func load(from url: URL) -> EmbeddingStore {
        (try? Data(contentsOf: url)).flatMap { EmbeddingStore(data: $0) } ?? EmbeddingStore()
    }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? serialized().write(to: url, options: .atomic)
    }
}

/// Ranking helpers kept free of the index so they can be tested on their own.
enum HybridRanking {
    /// Dot product, which is cosine similarity for unit vectors.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        guard sumOfSquares > 0 else { return vector }
        var scale = 1 / sumOfSquares.squareRoot()
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// Reciprocal-rank fusion: each ranking contributes `1 / (k + rank)` for every item it holds.
    ///
    /// BM25 scores and cosine similarities live on different scales, so adding them would let one
    /// drown the other. Ranks are comparable. An item high in either list surfaces, and one high in
    /// both wins. `k` damps the head so a single first place does not dominate.
    static func reciprocalRankFusion(_ rankings: [[Int]], k: Double = 60, topK: Int) -> [(index: Int, score: Double)] {
        var scores: [Int: Double] = [:]
        for ranking in rankings {
            for (position, item) in ranking.enumerated() {
                scores[item, default: 0] += 1 / (k + Double(position + 1))
            }
        }
        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(topK)
            .map { ($0.key, $0.value) }
    }
}
