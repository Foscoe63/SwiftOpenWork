import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// A persistent, ranked index over a workspace's source files.
///
/// The previous `workspace_semantic_search` rescanned every file on every query and scored with
/// raw token-frequency cosine similarity, which rewards long chunks and common words. This builds
/// an inverted index once, keeps it until files change, and ranks with BM25 — which discounts
/// terms that appear everywhere and normalises for chunk length.
///
/// BM25 alone is lexical: it will not connect "authentication" to a file that only ever says
/// "login". When Semantic Search is on and an embedding model is registered, each chunk also gets a
/// vector, built in the background and cached by chunk hash, and the two rankings are fused with
/// reciprocal-rank fusion. BM25 is always the fallback: while vectors are still being built, when
/// no model is installed, or when embedding fails, results are exactly what they were.
public actor CodeIndex {
    public static let shared = CodeIndex()

    /// Lines per chunk. Small enough to point at a specific function, large enough to carry
    /// surrounding context into the result.
    public static let chunkLines = 40
    /// Files larger than this are skipped: generated bundles and data blobs add noise, not signal.
    public static let maxFileBytes = 1_500_000

    public struct Chunk: Sendable, Equatable {
        public var path: String
        public var startLine: Int
        public var endLine: Int
        public var text: String
    }

    public struct Hit: Sendable, Equatable {
        public var chunk: Chunk
        public var score: Double
    }

    private struct Indexed {
        var chunks: [Chunk]
        /// term -> chunk indices containing it
        var postings: [String: [Int]]
        /// per-chunk token counts
        var lengths: [Int]
        var averageLength: Double
        /// path -> modification date, for incremental invalidation
        var stamps: [String: Date]
        /// Content hash of each chunk, the key its vector is cached under.
        var chunkKeys: [String]
    }

    private var cache: [String: Indexed] = [:]
    private var stores: [String: EmbeddingStore] = [:]
    private var embeddingTasks: [String: Task<Void, Never>] = [:]
    private var semanticNotes: [String: String] = [:]
    /// Roots whose embedding build failed. Not retried on every query; a rebuild clears it.
    private var failedRoots: Set<String> = []

    /// Chunks embedded per call to the model.
    static let embeddingBatchSize = 16
    /// A chunk is cut to this many characters before embedding; small encoders see about 512 tokens.
    static let embeddingCharacterLimit = 1_800
    /// Above this many chunks a workspace stays on BM25: the vectors would be slow to build and
    /// large to keep, for a repository the lexical index already handles well.
    static let maxEmbeddedChunks = 40_000

    private let semanticEnabled: @Sendable () -> Bool
    private let embedderProvider: @Sendable () -> (any TextEmbedder)?
    private let storeDirectory: URL

    init(
        semanticEnabled: @escaping @Sendable () -> Bool = { PersistenceManager.shared.loadSettings().semanticSearchEnabled },
        embedderProvider: @escaping @Sendable () -> (any TextEmbedder)? = { EmbedderRegistry.embedder },
        storeDirectory: URL = AppIdentity.homeDataDirectory.appendingPathComponent("embeddings", isDirectory: true)
    ) {
        self.semanticEnabled = semanticEnabled
        self.embedderProvider = embedderProvider
        self.storeDirectory = storeDirectory
    }

    // MARK: - Tokenisation

    /// Split identifiers the way code is actually written: `parseToolCall` and `parse_tool_call`
    /// both yield parse/tool/call, so a query in either style finds both.
    public nonisolated static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if current.count > 1 { tokens.append(current.lowercased()) }
            current = ""
        }

        for char in text {
            if char.isLetter || char.isNumber {
                if char.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                    flush()
                }
                current.append(char)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    // MARK: - Building

    /// Build or refresh the index for `root`. Unchanged files reuse their existing chunks.
    @discardableResult
    public func build(root: String, fileExtensions: Set<String>? = nil) -> Int {
        let paths = CodeSearch.glob(pattern: "**", root: root, limit: 20_000).paths
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        var stamps: [String: Date] = [:]
        var chunks: [Chunk] = []

        let existing = cache[root]
        for relative in paths {
            let ext = (relative as NSString).pathExtension.lowercased()
            if let fileExtensions, !fileExtensions.contains(ext) { continue }
            guard Self.isTextExtension(ext) else { continue }

            let full = rootPrefix + relative
            let attributes = try? FileManager.default.attributesOfItem(atPath: full)
            if let size = attributes?[.size] as? Int, size > Self.maxFileBytes { continue }
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            stamps[relative] = modified

            // Unchanged since the last build: reuse rather than re-reading.
            if let existing, existing.stamps[relative] == modified {
                chunks.append(contentsOf: existing.chunks.filter { $0.path == relative })
                continue
            }
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            chunks.append(contentsOf: Self.chunk(path: relative, content: content))
        }

        var postings: [String: [Int]] = [:]
        var lengths: [Int] = []
        var chunkKeys: [String] = []
        for (index, chunk) in chunks.enumerated() {
            chunkKeys.append(EmbeddingStore.key(for: chunk.text))
            let tokens = Self.tokenize(chunk.text)
            lengths.append(tokens.count)
            for term in Set(tokens) {
                postings[term, default: []].append(index)
            }
        }
        let average = lengths.isEmpty ? 1 : Double(lengths.reduce(0, +)) / Double(lengths.count)

        cache[root] = Indexed(
            chunks: chunks,
            postings: postings,
            lengths: lengths,
            averageLength: max(1, average),
            stamps: stamps,
            chunkKeys: chunkKeys
        )
        // A rebuilt index may hold chunks with no vector yet.
        embeddingTasks[root]?.cancel()
        embeddingTasks[root] = nil
        failedRoots.remove(root)
        return chunks.count
    }

    public static func chunk(path: String, content: String) -> [Chunk] {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }
        var out: [Chunk] = []
        var start = 0
        while start < lines.count {
            let end = min(start + chunkLines, lines.count)
            let text = lines[start..<end].joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Chunk(path: path, startLine: start + 1, endLine: end, text: text))
            }
            start = end
        }
        return out
    }

    public static func isTextExtension(_ ext: String) -> Bool {
        [
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "rb", "java",
            "kt", "kts", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh", "yml", "yaml", "json",
            "toml", "md", "txt", "cfg", "ini", "gradle", "podspec", "plist", "xcconfig", "sql",
        ].contains(ext)
    }

    // MARK: - Searching

    /// Ranked chunks for `query`: BM25 fused with vector similarity when vectors are available.
    public func search(query: String, root: String, topK: Int = 8) async -> [Hit] {
        await searchWithStatus(query: query, root: root, topK: topK).hits
    }

    /// As `search`, plus a one-line note when Semantic Search is on but this answer is lexical only,
    /// so the model and the user are not left thinking a vector search ran.
    public func searchWithStatus(query: String, root: String, topK: Int = 8) async -> (hits: [Hit], note: String?) {
        if cache[root] == nil { _ = build(root: root) }
        guard let index = cache[root], !index.chunks.isEmpty else { return ([], nil) }

        let terms = Set(Self.tokenize(query))
        let lexical = terms.isEmpty ? [] : bm25Ranking(index: index, terms: terms)

        guard semanticEnabled() else { return (hit(lexical.prefix(topK), in: index), nil) }
        guard let embedder = embedderProvider() else {
            return (hit(lexical.prefix(topK), in: index), "Semantic search is on but no embedding model is loaded; results are keyword-only.")
        }
        startEmbeddingIfNeeded(root: root, index: index, embedder: embedder)

        let store = stores[root] ?? loadStore(root: root, embedder: embedder)
        stores[root] = store
        guard store.count > 0 else {
            let building = embeddingTasks[root] != nil
            return (hit(lexical.prefix(topK), in: index), building
                ? "Semantic index is still being built; results are keyword-only for now."
                : semanticNotes[root] ?? "Semantic index is empty; results are keyword-only.")
        }

        var vectorRanking: [Int] = []
        do {
            let queryVector = try await embedder.embed([query], isQuery: true).first ?? []
            // The index may have been rebuilt while the query was being embedded.
            guard cache[root]?.chunkKeys == index.chunkKeys else {
                return (hit(lexical.prefix(topK), in: index), nil)
            }
            let unit = HybridRanking.normalized(queryVector)
            var scored: [(Int, Float)] = []
            for (position, key) in index.chunkKeys.enumerated() {
                guard let vector = store.vector(forKey: key) else { continue }
                scored.append((position, HybridRanking.dot(unit, vector)))
            }
            vectorRanking = scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(100).map(\.0)
        } catch {
            semanticNotes[root] = "Semantic search failed (\(error.localizedDescription)); results are keyword-only."
            return (hit(lexical.prefix(topK), in: index), semanticNotes[root])
        }

        let fused = HybridRanking.reciprocalRankFusion(
            [Array(lexical.prefix(100).map(\.index)), vectorRanking], topK: topK
        )
        let hits = fused.map { Hit(chunk: index.chunks[$0.index], score: $0.score) }
        let covered = store.count < index.chunks.count
        return (hits, covered && embeddingTasks[root] != nil ? "Semantic index is still being built; results use the part embedded so far." : nil)
    }

    private func hit<S: Sequence>(_ ranked: S, in index: Indexed) -> [Hit] where S.Element == (index: Int, score: Double) {
        ranked.map { Hit(chunk: index.chunks[$0.index], score: $0.score) }
    }

    /// BM25 constants: k1 damps repeated terms, b controls length normalisation.
    private func bm25Ranking(index: Indexed, terms: Set<String>) -> [(index: Int, score: Double)] {
        let k1 = 1.5
        let b = 0.75
        let total = Double(index.chunks.count)

        var scores: [Int: Double] = [:]
        for term in terms {
            guard let postings = index.postings[term] else { continue }
            let documentFrequency = Double(postings.count)
            // A term in nearly every chunk carries almost no information.
            let idf = log(1 + (total - documentFrequency + 0.5) / (documentFrequency + 0.5))
            for chunkIndex in postings {
                let tokens = Self.tokenize(index.chunks[chunkIndex].text)
                let frequency = Double(tokens.filter { $0 == term }.count)
                guard frequency > 0 else { continue }
                let length = Double(index.lengths[chunkIndex])
                let denominator = frequency + k1 * (1 - b + b * length / index.averageLength)
                scores[chunkIndex, default: 0] += idf * (frequency * (k1 + 1)) / denominator
            }
        }

        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (index: $0.key, score: $0.value) }
    }

    // MARK: - Embeddings

    private func storeURL(root: String, embedder: any TextEmbedder) -> URL {
        EmbeddingStore.fileURL(root: root, embedderId: embedder.identifier, in: storeDirectory)
    }

    private func loadStore(root: String, embedder: any TextEmbedder) -> EmbeddingStore {
        EmbeddingStore.load(from: storeURL(root: root, embedder: embedder))
    }

    /// Embed every chunk that has no cached vector, off the caller's path.
    ///
    /// Search never waits for this: it answers from BM25 and the vectors that exist, and each run
    /// saves as it goes, so an interrupted build resumes rather than restarts.
    private func startEmbeddingIfNeeded(root: String, index: Indexed, embedder: any TextEmbedder) {
        guard embeddingTasks[root] == nil, !failedRoots.contains(root),
              index.chunks.count <= Self.maxEmbeddedChunks else { return }
        var store = stores[root] ?? loadStore(root: root, embedder: embedder)
        let keys = Set(index.chunkKeys)
        store.retain(keys: keys)
        stores[root] = store

        var seen = Set<String>()
        let missing: [(key: String, text: String)] = index.chunks.enumerated().compactMap { position, chunk in
            let key = index.chunkKeys[position]
            guard store.vector(forKey: key) == nil, seen.insert(key).inserted else { return nil }
            return (key, String(chunk.text.prefix(Self.embeddingCharacterLimit)))
        }
        guard !missing.isEmpty else { return }

        let url = storeURL(root: root, embedder: embedder)
        embeddingTasks[root] = Task.detached(priority: .utility) { [weak self] in
            var batchStart = 0
            while batchStart < missing.count, !Task.isCancelled {
                let batch = Array(missing[batchStart..<min(batchStart + Self.embeddingBatchSize, missing.count)])
                do {
                    let vectors = try await embedder.embed(batch.map(\.text), isQuery: false)
                    guard vectors.count == batch.count else { throw EmbeddingError.countMismatch }
                    await self?.record(root: root, pairs: zip(batch.map(\.key), vectors.map(HybridRanking.normalized)).map { ($0, $1) })
                } catch {
                    await self?.embeddingFailed(root: root, error: error)
                    return
                }
                batchStart += Self.embeddingBatchSize
            }
            await self?.embeddingFinished(root: root, url: url, cancelled: Task.isCancelled)
        }
    }

    private func record(root: String, pairs: [(String, [Float])]) {
        var store = stores[root] ?? EmbeddingStore()
        for (key, vector) in pairs { store.insert(vector, forKey: key) }
        stores[root] = store
    }

    private func embeddingFailed(root: String, error: Error) {
        semanticNotes[root] = "Semantic indexing stopped (\(error.localizedDescription)); results are keyword-only."
        failedRoots.insert(root)
        embeddingTasks[root] = nil
    }

    private func embeddingFinished(root: String, url: URL, cancelled: Bool) {
        if !cancelled { semanticNotes[root] = nil }
        embeddingTasks[root] = nil
        stores[root]?.save(to: url)
    }

    /// Wait for the background embedding of `root` to finish. For tests and for callers that want
    /// the semantic half ready before they ask.
    func waitForEmbeddings(root: String) async {
        await embeddingTasks[root]?.value
    }

    enum EmbeddingError: LocalizedError {
        case countMismatch
        var errorDescription: String? { "the embedding model returned the wrong number of vectors" }
    }

    public func invalidate(root: String) {
        cache.removeValue(forKey: root)
        embeddingTasks[root]?.cancel()
        embeddingTasks[root] = nil
        failedRoots.remove(root)
    }

    public func indexedChunkCount(root: String) -> Int {
        cache[root]?.chunks.count ?? 0
    }

    // MARK: - Rendering

    public nonisolated static func format(_ hits: [Hit], query: String) -> String {
        guard !hits.isEmpty else {
            return "No indexed content matches \"\(query)\". Try `grep` for an exact string."
        }
        return hits.map { hit in
            "\(hit.chunk.path):\(hit.chunk.startLine)-\(hit.chunk.endLine)\n\(hit.chunk.text)"
        }.joined(separator: "\n\n---\n\n")
    }
}
