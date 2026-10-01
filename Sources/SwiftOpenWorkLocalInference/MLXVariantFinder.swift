import Foundation
import SwiftOpenWorkCore

/// Finds the other precisions of a catalog model on Hugging Face (`…-4bit`, `…-8bit`, `…-bf16`).
///
/// The curated list names one precision per model. Guessing sibling repo ids would offer downloads
/// that 401, which the catalog has done before, so this asks the Hub which exist. It runs only when
/// the user asks, never in the background.
public enum MLXVariantFinder {
    /// Sibling repos from a Hub search result that are the same model as `template` at another
    /// precision. Matching is on the normalised name, so `Qwen2.5.1-…` and fine-tunes that merely
    /// contain the name are left out.
    static func siblingIds(searchResult ids: [String], of template: LocalMLXModel) -> [String] {
        let key = template.variantGroupKey
        return ids.filter { id in
            // One whose precision the name does not state cannot be offered as a choice.
            guard id != template.id, LocalMLXModel.quantizationLabel(fromId: id) != nil else { return false }
            let candidate = LocalMLXModel(id: id, name: id, description: "")
            return candidate.variantGroupKey == key
        }
    }

    /// Total bytes of the weight files in a `?blobs=true` model response. Tokenizer and README
    /// files are not memory, so only `.safetensors` count.
    static func weightBytes(blobsJSON: Data) -> Int64? {
        guard let object = try? JSONSerialization.jsonObject(with: blobsJSON) as? [String: Any],
              let siblings = object["siblings"] as? [[String: Any]] else { return nil }
        let total = siblings.reduce(Int64(0)) { sum, file in
            guard let name = file["rfilename"] as? String, name.hasSuffix(".safetensors"),
                  let size = (file["size"] as? NSNumber)?.int64Value else { return sum }
            return sum + size
        }
        return total > 0 ? total : nil
    }

    /// The same model, at the precision named by `id`, sized from the weights it actually has.
    static func variant(id: String, weightBytes: Int64, template: LocalMLXModel) -> LocalMLXModel {
        // Same factor the curated entries use: weights plus the cache and activations a run needs.
        let ramGB = Double(weightBytes) / 1_000_000_000 * 1.084
        return LocalMLXModel(
            id: id,
            name: id.split(separator: "/").last.map(String.init) ?? id,
            description: template.description,
            sizeBytes: weightBytes,
            parameterCount: template.parameterCount,
            quantization: LocalMLXModel.quantizationLabel(fromId: id),
            modelType: template.modelType,
            contextWindow: template.contextWindow,
            isVLM: template.isVLM,
            useCase: template.useCase,
            estimatedRAMGB: (ramGB * 10).rounded() / 10,
            tags: template.tags
        )
    }

    /// Ask the Hub. At most `limit` siblings are sized, one small request each.
    public static func find(siblingsOf template: LocalMLXModel, limit: Int = 6) async throws -> [LocalMLXModel] {
        // A model published under its own org (ornith-ai/…) has siblings there or in
        // mlx-community, so search both rather than assume.
        let org = template.id.split(separator: "/").first.map(String.init) ?? "mlx-community"
        var ids: [String] = []
        for author in Set([org, "mlx-community"]) {
            var components = URLComponents(string: "https://huggingface.co/api/models")!
            components.queryItems = [
                URLQueryItem(name: "author", value: author),
                URLQueryItem(name: "search", value: template.variantGroupKey),
                URLQueryItem(name: "limit", value: "40"),
            ]
            guard let url = components.url else { continue }
            let (data, _) = try await URLSession.shared.data(from: url)
            if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                ids += list.compactMap { $0["id"] as? String }
            }
        }
        var found: [LocalMLXModel] = []
        for id in siblingIds(searchResult: Array(Set(ids)).sorted(), of: template).prefix(limit) {
            guard let url = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true") else { continue }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let bytes = weightBytes(blobsJSON: data) else { continue }
            found.append(variant(id: id, weightBytes: bytes, template: template))
        }
        return found
    }
}
