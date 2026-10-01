import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// Embeds code chunks with a small encoder (bge-small by default) running in MLX.
///
/// Like chat models, it never downloads on its own: an unattended background index must not start
/// pulling weights. Downloading is an explicit action in Settings, and until it has happened this
/// throws, which leaves `search_workspace` on BM25.
public actor MLXEmbeddingService: TextEmbedder {
    public static let shared = MLXEmbeddingService()

    /// The model named in Settings, so changing it there changes the cache key with it.
    public nonisolated var identifier: String { Self.configuredModelId() }

    private var container: EmbedderModelContainer?
    private var loadedModelId: String?

    /// Longest sequence handed to the encoder. Small BERT-style models are trained to 512.
    static let maxTokens = 512

    private init() {}

    static func configuredModelId() -> String {
        let id = PersistenceManager.shared.loadSettings().embeddingModelId
        return id.isEmpty ? AppSettings.defaultEmbeddingModelId : id
    }

    /// Queries and documents are embedded differently by retrieval models; using the wrong prefix,
    /// or none, costs noticeable accuracy.
    static func prefix(modelId: String, isQuery: Bool) -> String {
        let id = modelId.lowercased()
        if id.contains("nomic") { return isQuery ? "search_query: " : "search_document: " }
        if id.contains("bge") && !id.contains("bge-m3") {
            return isQuery ? "Represent this sentence for searching relevant passages: " : ""
        }
        if id.contains("e5") { return isQuery ? "query: " : "passage: " }
        return ""
    }

    public func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let modelId = Self.configuredModelId()
        let container = try await loadContainer(modelId: modelId)
        let prefix = Self.prefix(modelId: modelId, isQuery: isQuery)
        let inputs = texts.map { prefix + $0 }
        let layerNorm = modelId.lowercased().contains("nomic")

        let vectors: [[Float]] = await container.perform { (context: EmbedderModelContext) -> [[Float]] in
            let limit = min(Self.maxTokens, context.model.maxPositionEmbeddings ?? Self.maxTokens)
            let encoded = inputs.map { Array(context.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(limit)) }
            let width = max(1, encoded.map(\.count).max() ?? 1)
            // The mask comes from the real lengths. Comparing against the end-of-text id would also
            // blank a genuine separator token at the end of each sequence.
            var ids = [Int32](), mask = [Int32]()
            for row in encoded {
                ids += row.map { Int32($0) } + [Int32](repeating: 0, count: width - row.count)
                mask += [Int32](repeating: 1, count: row.count) + [Int32](repeating: 0, count: width - row.count)
            }
            let shape = [encoded.count, width]
            let idArray = MLXArray(ids, shape)
            let maskArray = MLXArray(mask, shape)
            let output = context.model(
                idArray, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: idArray), attentionMask: maskArray
            )
            let pooled = context.pooling(output, mask: maskArray, normalize: true, applyLayerNorm: layerNorm)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
        return vectors
    }

    private func loadContainer(modelId: String) async throws -> EmbedderModelContainer {
        if let container, loadedModelId == modelId { return container }
        guard let directory = LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: modelId, settings: PersistenceManager.shared.loadSettings()
        ) else {
            throw NSError(domain: "MLXEmbeddingService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the embedding model \(modelId) is not downloaded (Settings → Advanced → Semantic Search)",
            ])
        }
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: directory, using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        loadedModelId = modelId
        return loaded
    }

    /// Whether the configured model is already on this Mac.
    public nonisolated func isDownloaded() -> Bool {
        LocalMLXEngine.shared.resolveLocalModelDirectory(
            modelId: Self.configuredModelId(), settings: PersistenceManager.shared.loadSettings()
        ) != nil
    }

    /// Fetch the configured model into the same hub cache chat models use, so the next embed finds it.
    public func download(onProgress: @Sendable @escaping (Double, String) -> Void) async throws {
        let modelId = Self.configuredModelId()
        let root = NativeMLXService.downloadCacheRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hubClient = HubClient(cache: HubCache(cacheDirectory: root))
        let downloader = #hubDownloader(hubClient)
        onProgress(0, "Resolving \(modelId)…")
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: modelId, revision: "main"),
            progressHandler: { progress in
                let fraction = min(1, max(0, progress.fractionCompleted))
                onProgress(fraction, "Downloading \(modelId) — \(Int((fraction * 100).rounded()))%")
            }
        )
        loadedModelId = modelId
        onProgress(1, "Downloaded \(modelId)")
    }
}
