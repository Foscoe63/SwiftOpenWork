import Foundation

/// Turns text into unit-length vectors whose dot product is cosine similarity.
///
/// Lives in Core so the MLX module can implement it and the engine can consume it without either
/// depending on the other.
public protocol TextEmbedder: Sendable {
    /// Names the model. Part of the on-disk cache key, so changing the model never reuses vectors
    /// from another one.
    var identifier: String { get }

    /// One vector per text, in order. `isQuery` lets models that distinguish queries from
    /// documents (`search_query:` / `search_document:`) apply the right prefix.
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]]
}
